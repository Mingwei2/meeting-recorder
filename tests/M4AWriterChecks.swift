import AVFoundation
import AudioToolbox
import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw NSError(domain: "M4AWriterChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

@main
struct M4AWriterChecks {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-recorder-audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try await checkMixAndSplits(in: directory)
        try await checkShortAndEmpty(in: directory)
        try await checkExistingFiles(in: directory)
        if CommandLine.arguments.contains("--long") {
            try await checkLongRecording(in: directory)
        }
        print("Audio checks passed: AAC 48 kbps / mono / 24 kHz, complete timelines, bounded parts, safe file handling.")
    }

    private static func signal(start: Int, frames: Int) -> [Float] {
        var microphone = [Float](repeating: 0, count: frames * 2)
        var system = microphone
        for i in 0..<frames {
            let t = Double(start + i) / 48_000
            let mic = Float(0.16 * sin(2 * .pi * 600 * t))
            microphone[i * 2] = mic
            microphone[i * 2 + 1] = mic
            // A changing frequency detects missing/repeated/reordered samples across splits.
            system[i * 2] = Float(0.15 * sin(2 * .pi * (300 * t + 1.5 * t * t)))
            system[i * 2 + 1] = Float(0.15 * sin(2 * .pi * 1_200 * t))
        }
        return AudioMix.mix(microphone: microphone, system: system, frames: frames).samples
    }

    private static func checkMixAndSplits(in directory: URL) async throws {
        let writer = try M4AWriter(url: directory.appendingPathComponent("mixed.m4a"), sizeLimit: 256_000)
        let totalFrames = 48_000 * 67 + 14_400
        // Include a large final-style flush and chunks that do not align with AAC packets.
        let chunks = [624, 960, 12_000, 144_000, 38_112]
        var position = 0
        var chunkIndex = 0
        while position < totalFrames {
            let frames = min(chunks[chunkIndex % chunks.count], totalFrames - position)
            try writer.append(interleaved: signal(start: position, frames: frames))
            position += frames
            chunkIndex += 1
        }
        try await writer.finish()
        let files = writer.completedURLs
        try require(files.count >= 3, "Expected automatic splitting")
        try require(files[1].lastPathComponent == "mixed_02.m4a", "Part names must preserve order")
        try require(tryFiles(in: directory).count == files.count, "Only optimized parts should be saved")

        var decodedFrames: Int64 = 0
        for url in files {
            let file = try inspect(url, limit: 256_000)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: buffer)
            try require(Int64(buffer.frameLength) == file.length, "Part did not decode completely")
            let samples = buffer.floatChannelData![0]
            for offset in [2_400, Int(buffer.frameLength) - 12_000] {
                try require(offset >= 0, "Unexpected empty/tiny trailing part")
                var chirpSin = 0.0, chirpCos = 0.0, micSin = 0.0, micCos = 0.0, rightSin = 0.0, rightCos = 0.0
                let count = 9_600
                for i in offset..<(offset + count) {
                    let t = Double(decodedFrames + Int64(i)) / 24_000
                    let value = Double(samples[i])
                    let chirpPhase = 2 * Double.pi * (300 * t + 1.5 * t * t)
                    chirpSin += value * sin(chirpPhase)
                    chirpCos += value * cos(chirpPhase)
                    micSin += value * sin(2 * .pi * 600 * t)
                    micCos += value * cos(2 * .pi * 600 * t)
                    rightSin += value * sin(2 * .pi * 1_200 * t)
                    rightCos += value * cos(2 * .pi * 1_200 * t)
                }
                let scale = 2 / Double(count)
                try require(hypot(chirpSin, chirpCos) * scale > 0.035, "System left/timeline lost near a part boundary")
                try require(hypot(micSin, micCos) * scale > 0.09, "Microphone missing from mono output")
                try require(hypot(rightSin, rightCos) * scale > 0.035, "System right missing from mono output")
            }
            decodedFrames += Int64(buffer.frameLength)
        }
        try require(abs(decodedFrames - Int64(totalFrames / 2)) <= 1, "Splitting changed the total decoded duration")
        try await writer.finish()
        try require(writer.completedURLs == files, "Finishing twice changed the parts")
        var refused = false
        do { try writer.append(interleaved: [0, 0]) } catch { refused = true }
        try require(refused, "Append after finish must fail")
        print("Mixed input: \(totalFrames) frames -> \(decodedFrames) mono frames in \(files.count) parts; both sources retained.")
    }

    private static func checkShortAndEmpty(in directory: URL) async throws {
        for seconds in [0, 1, 20] {
            let writer = try M4AWriter(url: directory.appendingPathComponent("short-\(seconds).m4a"), sizeLimit: 256_000)
            if seconds > 0 { try writer.append(interleaved: signal(start: 0, frames: seconds * 48_000)) }
            try writer.append(interleaved: [])
            try await writer.finish()
            try require(writer.completedURLs.count == 1, "Short recording created an extra part")
            let file = try inspect(writer.completedURLs[0], limit: 256_000)
            try require(file.length == Int64(seconds == 0 ? 4_800 : seconds * 24_000), "Short recording duration changed")
        }
    }

    private static func checkExistingFiles(in directory: URL) async throws {
        let url = directory.appendingPathComponent("collision.m4a")
        let sentinel = Data("existing recording".utf8)
        try sentinel.write(to: url)
        var refused = false
        do { _ = try M4AWriter(url: url) } catch { refused = true }
        try require(refused, "Existing first file must not be overwritten")
        let original = try Data(contentsOf: url)
        try require(original == sentinel, "Existing recording was modified")

        let part = directory.appendingPathComponent("collision-next_02.m4a")
        try sentinel.write(to: part)
        let writer = try M4AWriter(url: directory.appendingPathComponent("collision-next.m4a"), sizeLimit: 256_000)
        try writer.append(interleaved: signal(start: 0, frames: 20 * 48_000))
        refused = false
        do { try writer.append(interleaved: signal(start: 20 * 48_000, frames: 48_000)) } catch { refused = true }
        try require(refused, "Existing next part must not be overwritten")
        try await writer.finish()
        let existingPart = try Data(contentsOf: part)
        try require(existingPart == sentinel, "Existing next part was modified")
        let saved = try inspect(writer.completedURLs[0], limit: 256_000)
        try require(saved.length == 20 * 24_000, "Failed rollover lost previously recorded audio")
    }

    private static func checkLongRecording(in directory: URL) async throws {
        let writer = try M4AWriter(url: directory.appendingPathComponent("long.m4a"))
        // Deterministic broadband input stresses the encoder and file-size budget.
        var seed: UInt64 = 7
        var noise = [Float](repeating: 0, count: 48_000 * 2)
        for i in noise.indices {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1
            noise[i] = Float(Double(seed >> 32) / Double(UInt32.max) - 0.5) * 0.8
        }
        let seconds = 70 * 60
        for second in 0..<seconds {
            try writer.append(interleaved: noise)
            if second.isMultiple(of: 600) { print("Long recording: \(second / 60)/70 minutes encoded") }
        }
        try await writer.finish()
        try require(writer.completedURLs.count == 2, "70-minute recording should split automatically")
        var frames: Int64 = 0
        for url in writer.completedURLs {
            let file = try inspect(url, limit: 25_000_000)
            frames += file.length
            let bytes = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! NSNumber
            print("Long part: \(url.lastPathComponent), \(bytes) bytes, \(Double(file.length) / 24_000) seconds")
        }
        try require(frames == Int64(seconds * 24_000), "Long recording lost duration")
    }

    private static func inspect(_ url: URL, limit: Int64) throws -> AVAudioFile {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attributes[.size] as! NSNumber).int64Value
        try require(bytes > 0 && bytes < limit, "\(url.lastPathComponent) exceeds its upload limit: \(bytes)")
        let file = try AVAudioFile(forReading: url)
        let format = file.fileFormat.streamDescription.pointee
        try require(format.mFormatID == kAudioFormatMPEG4AAC, "Output must remain AAC/m4a")
        try require(format.mSampleRate == 24_000 && format.mChannelsPerFrame == 1, "Output must be 24 kHz mono")
        try require(file.length > 0, "Part must contain playable audio")
        return file
    }

    private static func tryFiles(in directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    }
}
