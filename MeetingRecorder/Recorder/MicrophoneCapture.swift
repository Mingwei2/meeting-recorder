import AVFoundation
import Foundation
import os

/// Microphone via AVAudioEngine.
///
/// Voice processing is intentionally off. `setVoiceProcessingEnabled(true)` builds
/// a VPIO aggregate that silences ScreenCaptureKit system-audio capture.
final class MicrophoneCapture {
    var onPCM: ((AVAudioPCMBuffer) -> Void)?
    var onInterruption: ((Error) -> Void)?

    private let engine = AVAudioEngine()
    private let converter = PCMConverter()
    private var observer: NSObjectProtocol?
    private var running = false
    private var startedAt = Date.distantPast
    private let log = Logger(subsystem: "local.meetingrecorder.app", category: "microphone")

    func start() throws {
        guard converter != nil else {
            throw RecorderError.noMicrophoneDevice
        }
        // `inputNode` raises an ObjC exception when the Mac has no input device.
        // Swift cannot catch that, so check before touching the engine.
        guard AVCaptureDevice.default(for: .audio) != nil else {
            throw RecorderError.noMicrophoneDevice
        }
        running = true
        startedAt = Date()
        try installTap()
        engine.prepare()
        do {
            try engine.start()
        } catch {
            running = false
            engine.inputNode.removeTap(onBus: 0)
            throw error
        }
        observeConfigurationChanges()
    }

    func stop() {
        running = false
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func installTap() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw RecorderError.noMicrophoneDevice
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self, let converted = self.converter?.convert(buffer) else { return }
            self.onPCM?(converted)
        }
    }

    private func observeConfigurationChanges() {
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    private func handleConfigurationChange() {
        // Starting the engine can post this notification immediately. Ignore that echo.
        guard running, Date().timeIntervalSince(startedAt) > 0.6 else { return }
        log.info("Microphone configuration changed; reinstalling tap.")
        engine.inputNode.removeTap(onBus: 0)
        do {
            try installTap()
            if !engine.isRunning {
                try engine.start()
            }
        } catch {
            log.error("Microphone restart failed: \(error.localizedDescription, privacy: .public)")
            onInterruption?(error)
        }
    }
}
