import Darwin
import Foundation

enum AudioMix {
    /// Sum microphone and system-audio interleaved stereo, then soft-clip.
    /// Each source is scaled slightly under unity so one talker stays clear
    /// and two loud talkers bend instead of hard-clipping.
    static func mix(microphone: [Float], system: [Float], frames: Int) -> (samples: [Float], micPeak: Float, systemPeak: Float) {
        var mixed = [Float](repeating: 0, count: frames * 2)
        var micPeak: Float = 0
        var systemPeak: Float = 0
        let micFrames = microphone.count / 2
        let systemFrames = system.count / 2
        let gain: Float = 0.9

        for index in 0..<frames {
            var left: Float = 0
            var right: Float = 0
            if index < micFrames {
                let micLeft = microphone[index * 2]
                let micRight = microphone[index * 2 + 1]
                micPeak = max(micPeak, abs(micLeft), abs(micRight))
                left += micLeft * gain
                right += micRight * gain
            }
            if index < systemFrames {
                let systemLeft = system[index * 2]
                let systemRight = system[index * 2 + 1]
                systemPeak = max(systemPeak, abs(systemLeft), abs(systemRight))
                left += systemLeft * gain
                right += systemRight * gain
            }
            mixed[index * 2] = softClip(left)
            mixed[index * 2 + 1] = softClip(right)
        }
        return (mixed, micPeak, systemPeak)
    }

    /// Knee at ±0.9. Output stays inside ±1.
    static func softClip(_ sample: Float) -> Float {
        let magnitude = abs(sample)
        let threshold: Float = 0.9
        if magnitude <= threshold {
            return sample
        }
        let sign: Float = sample < 0 ? -1 : 1
        let excess = (magnitude - threshold) / (1 - threshold)
        let shaped = threshold + (1 - threshold) * tanh(excess)
        return sign * shaped
    }
}
