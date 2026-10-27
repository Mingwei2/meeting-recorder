import AVFoundation
import Foundation
import os

/// Converts whatever a capture callback hands us into 48 kHz, stereo, Float32, non-interleaved.
final class PCMConverter {
    private let target: AVAudioFormat
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    init?() {
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ) else {
            return nil
        }
        self.target = target
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0 else { return nil }
        let source = buffer.format
        guard source.sampleRate > 0, source.channelCount > 0 else { return nil }

        if converter == nil || sourceFormat != source {
            guard let created = AVAudioConverter(from: source, to: target) else {
                return nil
            }
            created.sampleRateConverterQuality = .high
            converter = created
            sourceFormat = source
        }
        guard let converter else { return nil }

        let ratio = target.sampleRate / source.sampleRate
        let estimated = Double(buffer.frameLength) * ratio
        let capacity = AVAudioFrameCount(estimated.rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: max(capacity, 32)) else {
            return nil
        }

        var error: NSError?
        var consumed = false
        let status = converter.convert(to: output, error: &error) { _, statusOut in
            if consumed {
                statusOut.pointee = .noDataNow
                return nil
            }
            consumed = true
            statusOut.pointee = .haveData
            return buffer
        }
        if status == .error {
            Logger(subsystem: "local.meetingrecorder.app", category: "convert")
                .error("PCM convert failed: \(error?.localizedDescription ?? "unknown", privacy: .public)")
            return nil
        }
        guard output.frameLength > 0, let channels = output.floatChannelData else {
            return nil
        }
        // Mono sources sometimes land on channel 0 only. Duplicate so the mix stays centered.
        if source.channelCount == 1, output.format.channelCount > 1 {
            channels[1].update(from: channels[0], count: Int(output.frameLength))
        }
        return output
    }
}
