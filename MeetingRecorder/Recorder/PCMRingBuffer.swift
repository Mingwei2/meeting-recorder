import AVFoundation
import Foundation

/// Interleaved-stereo ring buffer. Capture callbacks write; the mixer reads.
/// Overflow drops the oldest frames so a stalled writer cannot grow without bound.
final class PCMRingBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let capacity: Int
    private var storage: [Float]
    private var readIndex = 0
    private var writeIndex = 0
    private var stored = 0
    private var acceptedFrames = 0
    private(set) var overrunFrames = 0

    init(capacityFrames: Int) {
        capacity = max(1, capacityFrames)
        storage = [Float](repeating: 0, count: capacity * 2)
    }

    var availableFrames: Int {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    /// Frames successfully copied in, including ones later dropped as overrun.
    var acceptedFrameCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return acceptedFrames
    }

    func write(nonInterleaved buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        guard frames > 0,
              buffer.format.commonFormat == .pcmFormatFloat32,
              let channels = buffer.floatChannelData,
              buffer.format.channelCount >= 1
        else {
            return
        }

        let left = channels[0]
        let right = buffer.format.channelCount > 1 ? channels[1] : channels[0]

        lock.lock()
        defer { lock.unlock() }

        var toWrite = frames
        var leftPointer = left
        var rightPointer = right
        if toWrite > capacity {
            let skip = toWrite - capacity
            leftPointer = left.advanced(by: skip)
            rightPointer = right.advanced(by: skip)
            toWrite = capacity
            overrunFrames += skip
        }

        let overflow = stored + toWrite - capacity
        if overflow > 0 {
            readIndex = (readIndex + overflow) % capacity
            stored -= overflow
            overrunFrames += overflow
        }

        for offset in 0..<toWrite {
            let destination = (writeIndex + offset) % capacity
            storage[destination * 2] = leftPointer[offset]
            storage[destination * 2 + 1] = rightPointer[offset]
        }
        writeIndex = (writeIndex + toWrite) % capacity
        stored += toWrite
        acceptedFrames += toWrite
    }

    /// Copies up to `frameCount` interleaved stereo frames into `destination`.
    /// Returns how many frames were copied. Unread tail of `destination` is left untouched.
    @discardableResult
    func readInterleaved(into destination: UnsafeMutablePointer<Float>, frameCount: Int) -> Int {
        guard frameCount > 0 else { return 0 }
        lock.lock()
        defer { lock.unlock() }
        let count = min(frameCount, stored)
        for offset in 0..<count {
            let source = (readIndex + offset) % capacity
            destination[offset * 2] = storage[source * 2]
            destination[offset * 2 + 1] = storage[source * 2 + 1]
        }
        readIndex = (readIndex + count) % capacity
        stored -= count
        return count
    }
}
