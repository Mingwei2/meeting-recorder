import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation

/// Writes a continuous 48 kHz stereo AAC stream into one `.m4a`.
/// Call every method from the mixer queue except `finish`, which may hop out via its completion.
final class M4AWriter {
    let url: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let format: CMFormatDescription
    private var sessionStarted = false
    private(set) var writtenFrames: Int64 = 0

    init(url: URL) throws {
        self.url = url
        writer = try AVAssetWriter(url: url, fileType: .m4a)
        // Fragmented m4a survives a crash or force-quit with at most ~10s of loss.
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000.0,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw RecorderError.writerFailed("编码器不接受这个音频格式。")
        }
        writer.add(input)
        format = try M4AWriter.makePCMFormat()
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
