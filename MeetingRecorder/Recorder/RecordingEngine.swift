import Foundation
import os

/// Mixes microphone + system audio on one timeline, automatically splitting large recordings.
final class RecordingEngine {
    struct Levels: Sendable {
        var microphone: Float
        var system: Float
        var systemFrames: Int
    }

    var onLevels: ((Levels) -> Void)?
    var onNotice: ((String) -> Void)?
    var onFatal: ((Error) -> Void)?

    private let mixerQueue = DispatchQueue(label: "local.meetingrecorder.mixer", qos: .userInitiated)
    private let microphone = MicrophoneCapture()
    private let systemAudio = SystemAudioCapture()
    private let microphoneRing = PCMRingBuffer(capacityFrames: 48_000 * 30)
    private let systemRing = PCMRingBuffer(capacityFrames: 48_000 * 30)
    private var writer: M4AWriter?
    private var timer: DispatchSourceTimer?
    private var startUptime: UInt64 = 0
    private var writtenFrames: Int64 = 0
    private var outputURL: URL?
    private var stopped = false
    private var fatalSent = false
    private var lastLevelPublish: UInt64 = 0
    private var warnedMissingSystemAudio = false
    private let log = Logger(subsystem: "local.meetingrecorder.app", category: "engine")

    private static let sampleRate: UInt64 = 48_000

    func start(outputURL: URL, target: SystemAudioTarget) async throws {
        self.outputURL = outputURL

        microphone.onPCM = { [microphoneRing] buffer in
            microphoneRing.write(nonInterleaved: buffer)
        }
        systemAudio.onPCM = { [systemRing] buffer in
            systemRing.write(nonInterleaved: buffer)
        }
        systemAudio.onInterruption = { [weak self] error in
            self?.fail(RecorderError.interrupted(RecorderError.message(from: error)))
        }
        microphone.onInterruption = { [weak self] error in
            self?.fail(RecorderError.interrupted("麦克风中断：\(error.localizedDescription)"))
        }

        do {
            try await systemAudio.validate(target)
        } catch {
            clearCaptureCallbacks()
            systemAudio.cancelValidation()
            self.outputURL = nil
            throw error
        }

        do {
            let writer = try M4AWriter(url: outputURL)
            self.writer = writer
        } catch {
            await abandonPreparedCapture(removeFileAt: outputURL, stopMicrophone: false)
            throw error
        }

        do {
            try microphone.start()
        } catch {
            let stopMicrophone: Bool
            if case RecorderError.noMicrophoneDevice = error {
                stopMicrophone = false
            } else {
                stopMicrophone = true
            }
            await abandonPreparedCapture(removeFileAt: outputURL, stopMicrophone: stopMicrophone)
            throw error
        }

        let report: SystemAudioStartReport
        do {
            report = try await systemAudio.startValidated()
        } catch {
            await abandonPreparedCapture(removeFileAt: outputURL, stopMicrophone: true)
            throw error
        }

        if !report.skippedNames.isEmpty {
            onNotice?(RecorderError.skippedApplicationsNotice(report.skippedNames))
        }

        startUptime = DispatchTime.now().uptimeNanoseconds
        let timer = DispatchSource.makeTimerSource(queue: mixerQueue)
        timer.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20), leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in
            self?.pull()
        }
        self.timer = timer
        timer.resume()
    }

    /// Returns successfully finalized parts in chronological order.
    func stop() async -> [URL] {
        let shouldRun: Bool = mixerQueue.sync {
            if stopped { return false }
            stopped = true
            timer?.cancel()
            timer = nil
            return true
        }
        guard shouldRun else { return writer?.completedURLs ?? [] }

        microphone.onPCM = nil
        systemAudio.onPCM = nil
        microphone.onInterruption = nil
        systemAudio.onInterruption = nil
        await systemAudio.stop()
        microphone.stop()

        let flushError = await withCheckedContinuation { (continuation: CheckedContinuation<Error?, Never>) in
            mixerQueue.async {
                do {
                    try self.flushRemainder()
                    continuation.resume(returning: nil)
                } catch {
                    continuation.resume(returning: error)
                }
            }
        }
        if let flushError { onNotice?(RecorderError.message(from: flushError)) }
        if let writer {
            do {
                try await writer.finish()
            } catch {
                log.error("Finish failed: \(error.localizedDescription, privacy: .public)")
                onNotice?(RecorderError.message(from: error))
            }
        }
        return writer?.completedURLs ?? []
    }

    private func clearCaptureCallbacks() {
        microphone.onPCM = nil
        microphone.onInterruption = nil
        systemAudio.onPCM = nil
        systemAudio.onInterruption = nil
    }

    /// Drops a prepared or just-started capture when writer, mic, or the stream fails.
    private func abandonPreparedCapture(removeFileAt url: URL, stopMicrophone: Bool) async {
        clearCaptureCallbacks()
        systemAudio.cancelValidation()
        await systemAudio.stop()
        if stopMicrophone {
            microphone.stop()
        }
        if writer != nil {
            writer = nil
            try? FileManager.default.removeItem(at: url)
        }
        outputURL = nil
    }

    private func fail(_ error: Error) {
        mixerQueue.async {
            guard !self.fatalSent else { return }
            self.fatalSent = true
            self.onFatal?(error)
        }
    }

    /// During the first 700ms, wait until both sources have audio so the file
    /// does not open with a pad of silence that permanently delays a late source.
    /// After that, missing samples become silence and the file length follows the clock.
    private func pull() {
        guard !stopped, let writer else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = now &- startUptime
        let expected = Int64(elapsed * Self.sampleRate / 1_000_000_000)
        var due = expected - writtenFrames
        if due <= 0 { return }
        // Catch up a little each tick. Samples already queued are real audio;
        // a shortfall is silence on the wall clock, not a reason to delay the other source.
        if due > 12_000 { due = 12_000 }
        let frames = Int(due)

        if !warnedMissingSystemAudio, elapsed > 2_000_000_000, systemRing.acceptedFrameCount == 0 {
            warnedMissingSystemAudio = true
            log.warning("No system-audio frames yet.")
            onNotice?("还没有收到系统音频。请确认「屏幕录制」已允许，并且允许后完全退出并重新打开过本应用。所选应用需要正在出声。")
        }

        var mic = [Float](repeating: 0, count: frames * 2)
        var system = [Float](repeating: 0, count: frames * 2)
        mic.withUnsafeMutableBufferPointer { pointer in
            _ = microphoneRing.readInterleaved(into: pointer.baseAddress!, frameCount: frames)
        }
        system.withUnsafeMutableBufferPointer { pointer in
            _ = systemRing.readInterleaved(into: pointer.baseAddress!, frameCount: frames)
        }

        let mixed = AudioMix.mix(microphone: mic, system: system, frames: frames)
        do {
            try writer.append(interleaved: mixed.samples)
            writtenFrames += Int64(frames)
        } catch {
            fail(error)
            return
        }

        if now &- lastLevelPublish > 80_000_000 {
            lastLevelPublish = now
            let levels = Levels(
                microphone: mixed.micPeak,
                system: mixed.systemPeak,
                systemFrames: systemRing.acceptedFrameCount
            )
            onLevels?(levels)
        }
    }

    private func flushRemainder() throws {
        guard let writer else { return }
        let frames = min(max(microphoneRing.availableFrames, systemRing.availableFrames), 48_000 * 3)
        guard frames > 0 else { return }
        var mic = [Float](repeating: 0, count: frames * 2)
        var system = [Float](repeating: 0, count: frames * 2)
        mic.withUnsafeMutableBufferPointer { pointer in
            _ = microphoneRing.readInterleaved(into: pointer.baseAddress!, frameCount: frames)
        }
        system.withUnsafeMutableBufferPointer { pointer in
            _ = systemRing.readInterleaved(into: pointer.baseAddress!, frameCount: frames)
        }
        let mixed = AudioMix.mix(microphone: mic, system: system, frames: frames)
        try writer.append(interleaved: mixed.samples)
        writtenFrames += Int64(frames)
    }
}
