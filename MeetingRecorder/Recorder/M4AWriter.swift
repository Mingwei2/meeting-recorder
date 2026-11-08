import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation

/// Accepts the mixer's 48 kHz stereo PCM and saves speech-sized AAC files.
/// Append on the mixer queue; call finish only after all appends have stopped.
final class M4AWriter {
    static let maximumFileBytes: Int64 = 25_000_000

    private let url: URL
    private let sizeLimit: Int64
    private let splitAtBytes: Int64
    private var current: AACFileWriter
    private var pending: [(url: URL, task: Task<Void, Error>)] = []
    private var finishing = false
    private var nextSizeCheckFrame: Int64 = 48_000
    private var diskBytes: Int64 = 0
    private(set) var completedURLs: [URL] = []

    init(url: URL, sizeLimit: Int64 = M4AWriter.maximumFileBytes) throws {
        // Leave room for buffered packets, the last fragment, and the m4a index.
        guard sizeLimit >= 256_000, sizeLimit <= Self.maximumFileBytes else {
            throw RecorderError.writerFailed("分片大小超出支持范围。")
        }
        self.url = url
        self.sizeLimit = sizeLimit
        splitAtBytes = sizeLimit - min(1_000_000, max(128_000, sizeLimit / 20))
        current = try AACFileWriter(url: url)
    }

    func append(interleaved samples: [Float]) throws {
        guard !finishing else {
            throw RecorderError.writerFailed("录音文件已经结束。")
        }
        guard samples.count.isMultiple(of: 2) else {
            throw RecorderError.writerFailed("音频数据不是完整的立体声帧。")
        }
        // Bound each append even when the final microphone/system buffers are flushed.
        var offset = 0
        while offset < samples.count {
            let count = min(48_000 * 2, samples.count - offset)
            if current.writtenFrames >= nextSizeCheckFrame {
                let attributes = try FileManager.default.attributesOfItem(atPath: current.url.path)
                diskBytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
                nextSizeCheckFrame = current.writtenFrames + 48_000
            }
            // CBR payload + a conservative allowance for fragment/sample tables.
            // This also bounds size while AVAssetWriter is buffering a fragment.
            let estimatedBytes = (current.writtenFrames + Int64(count / 2)) * 6_200 / 48_000
            if current.writtenFrames > 0, max(diskBytes, estimatedBytes) >= splitAtBytes {
                let nextURL = url.deletingLastPathComponent().appendingPathComponent(
                    "\(url.deletingPathExtension().lastPathComponent)_\(String(format: "%02d", pending.count + 2)).m4a"
                )
                // Open the next file before retiring the current one; never overwrite a file.
                let next = try AACFileWriter(url: nextURL)
                finishLater(current)
                current = next
                diskBytes = 0
                nextSizeCheckFrame = 48_000
            }
            let chunk = count == samples.count ? samples : Array(samples[offset..<(offset + count)])
            try current.append(interleaved: chunk)
            offset += count
        }
    }

    func finish() async throws {
        if !finishing {
            finishing = true
            finishLater(current)
        }
        var files: [URL] = []
        var failure: Error?
        // Always finish every part, even if another part failed to close.
        for part in pending {
            do {
                try await part.task.value
                files.append(part.url)
            } catch {
                if failure == nil { failure = error }
            }
        }
        completedURLs = files
        if let failure { throw failure }
    }

    private func finishLater(_ file: AACFileWriter) {
        let limit = sizeLimit
        pending.append((file.url, Task {
            try await file.finish()
            let attributes = try FileManager.default.attributesOfItem(atPath: file.url.path)
            guard let bytes = attributes[.size] as? NSNumber, bytes.int64Value < limit else {
                throw RecorderError.writerFailed("\(file.url.lastPathComponent) 超出分片大小限制，文件已保留。")
            }
        }))
    }
}

private final class AACFileWriter {
    let url: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let format: CMFormatDescription
    private var sessionStarted = false
    private(set) var writtenFrames: Int64 = 0

    init(url: URL) throws {
        self.url = url
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw RecorderError.writerFailed("文件已存在：\(url.lastPathComponent)")
        }
        writer = try AVAssetWriter(url: url, fileType: .m4a)
        // Fragmented m4a survives a crash or force-quit with at most ~10s of loss.
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 24_000.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 48_000,
            AVEncoderBitRateStrategyKey: AVAudioBitRateStrategy_Constant,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw RecorderError.writerFailed("编码器不接受这个音频格式。")
        }
        writer.add(input)
        format = try Self.makePCMFormat()
    }

    func append(interleaved samples: [Float]) throws {
        let frames = samples.count / 2
        guard frames > 0 else { return }
        try openSessionIfNeeded()

        guard let sampleBuffer = makeSampleBuffer(samples: samples, frames: frames, presentationFrame: writtenFrames) else {
            throw RecorderError.writerFailed("无法封装音频数据。")
        }

        var spins = 0
        while !input.isReadyForMoreMediaData && spins < 80 {
            if writer.status == .failed {
                throw RecorderError.writerFailed(writer.error?.localizedDescription ?? "写入器失败")
            }
            Thread.sleep(forTimeInterval: 0.005)
            spins += 1
        }
        guard writer.status == .writing, input.isReadyForMoreMediaData else {
            throw RecorderError.writerFailed(writer.error?.localizedDescription ?? "编码器忙，没能写入。")
        }
        guard input.append(sampleBuffer) else {
            throw RecorderError.writerFailed(writer.error?.localizedDescription ?? "写入音频帧失败。")
        }
        writtenFrames += Int64(frames)
    }

    func finish() async throws {
        if !sessionStarted {
            // Still produce a valid, playable file the user can find.
            try append(interleaved: [Float](repeating: 0, count: 48_000 / 5 * 2))
        }
        input.markAsFinished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting {
                continuation.resume()
            }
        }
        if writer.status != .completed {
            throw RecorderError.writerFailed(writer.error?.localizedDescription ?? "文件没有完成。")
        }
    }

    private func openSessionIfNeeded() throws {
        guard !sessionStarted else { return }
        guard writer.startWriting() else {
            throw RecorderError.writerFailed(writer.error?.localizedDescription ?? "无法开始写入文件。")
        }
        writer.startSession(atSourceTime: .zero)
        sessionStarted = true
    }

    private func makeSampleBuffer(samples: [Float], frames: Int, presentationFrame: Int64) -> CMSampleBuffer? {
        let byteCount = frames * 2 * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        let createStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block
        )
        guard createStatus == noErr, let block else { return nil }

        let replaceStatus = samples.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(
                with: raw.baseAddress!,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
        }
        guard replaceStatus == noErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: CMTimeValue(frames), timescale: 48_000),
            presentationTimeStamp: CMTime(value: presentationFrame, timescale: 48_000),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        // Sample size lives in the format description (8 bytes per interleaved frame).
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: frames,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr else { return nil }
        return sampleBuffer
    }

    private static func makePCMFormat() throws -> CMFormatDescription {
        var basic = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        var description: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &basic,
            layoutSize: MemoryLayout<AudioChannelLayout>.size,
            layout: &layout,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &description
        )
        guard status == noErr, let description else {
            throw RecorderError.writerFailed("无法创建 PCM 格式描述（\(status)）。")
        }
        return description
    }
}
