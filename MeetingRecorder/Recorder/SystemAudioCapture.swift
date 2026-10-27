import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import os
import ScreenCaptureKit

/// Display-wide ScreenCaptureKit audio capture.
///
/// Video is not the product. A 2×2, 1 fps stream still has to exist because
/// ScreenCaptureKit's video pipeline runs even for audio, and a missing screen
/// output spams "dropping frame". `CMTime(value:timescale:)` is the *minimum
/// gap* between frames — 1/1 is 1 fps. Do not "optimize" this to `CMTimeScale.max`;
/// that requests the display's native refresh rate.
///
/// Microphone is captured separately. ScreenCaptureKit's `.microphone` output
/// (macOS 15+) is a different clock and is intentionally unused.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    var onPCM: ((AVAudioPCMBuffer) -> Void)?
    var onInterruption: ((Error) -> Void)?

    private let audioQueue = DispatchQueue(label: "local.meetingrecorder.system-audio", qos: .userInitiated)
    private let videoQueue = DispatchQueue(label: "local.meetingrecorder.video-discard", qos: .background)
    private let converter = PCMConverter()
    private var stream: SCStream?
    private var intentionalStop = false
    private let log = Logger(subsystem: "local.meetingrecorder.app", category: "system-audio")

    func start() async throws {
        intentionalStop = false
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = Self.preferredDisplay(in: content.displays) else {
            throw RecorderError.noDisplay
        }
        let configuration = Self.makeConfiguration()

        do {
            let created = try makeStream(content: content, display: display, configuration: configuration, allApplications: true)
            try await start(created)
            log.info("System audio stream started (all applications).")
        } catch {
            log.error("All-application filter failed: \(error.localizedDescription, privacy: .public). Retrying display filter.")
            let created = try makeStream(content: content, display: display, configuration: configuration, allApplications: false)
            do {
                try await start(created)
            } catch {
                stream = nil
                throw map(error)
            }
        }
    }

    func stop() async {
        intentionalStop = true
        guard let stream else { return }
        self.stream = nil
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                try? await stream.stopCapture()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
            _ = await group.next()
            group.cancelAll()
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else {
            return
        }
        guard CMSampleBufferIsValid(sampleBuffer), CMSampleBufferGetNumSamples(sampleBuffer) > 0 else {
            return
        }
        if Self.shouldDrop(sampleBuffer) {
            return
        }
        guard let pcm = Self.pcmBuffer(from: sampleBuffer), let converted = converter?.convert(pcm) else {
            return
        }
        onPCM?(converted)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log.error("Stream stopped: \(error.localizedDescription, privacy: .public)")
        guard !intentionalStop else { return }
        onInterruption?(error)
    }

    private func start(_ created: SCStream) async throws {
        try created.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        try created.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        stream = created
        do {
            try await created.startCapture()
        } catch {
            stream = nil
            try? await created.stopCapture()
            throw error
        }
    }

    private func makeStream(
        content: SCShareableContent,
        display: SCDisplay,
        configuration: SCStreamConfiguration,
        allApplications: Bool
    ) throws -> SCStream {
        let bundleID = Bundle.main.bundleIdentifier
        let mine = content.applications.filter { $0.bundleIdentifier == bundleID }
        let filter: SCContentFilter
        if allApplications {
            let others = content.applications.filter { $0.bundleIdentifier != bundleID }
            if others.isEmpty {
                filter = SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: [])
            } else {
                // Audio follows the application list, so a window on another display is included.
                filter = SCContentFilter(display: display, including: others, exceptingWindows: [])
            }
        } else {
            filter = SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: [])
        }
        return SCStream(filter: filter, configuration: configuration, delegate: self)
    }

    private func map(_ error: Error) -> Error {
        let ns = error as NSError
        if ns.code == -3801 || ns.code == -3803 {
            return RecorderError.screenCaptureDenied
        }
        if ns.code == -3818 {
            return RecorderError.systemAudioFailed(ns.localizedDescription)
        }
        return error
    }

    private static func preferredDisplay(in displays: [SCDisplay]) -> SCDisplay? {
        let mainID = CGMainDisplayID()
        return displays.first { $0.displayID == mainID } ?? displays.first
    }

    private static func makeConfiguration() -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = true
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.showsCursor = false
        configuration.queueDepth = 3
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.scalesToFit = true
        return configuration
    }

    private static func shouldDrop(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw)
        else {
            return false
        }
        switch status {
        case .idle, .blank, .suspended:
            return true
        case .complete, .started, .stopped:
            return false
        @unknown default:
            return false
        }
    }

    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return nil
        }
        let samples = CMSampleBufferGetNumSamples(sampleBuffer)
        guard samples > 0,
              let format = AVAudioFormat(cmAudioFormatDescription: formatDescription),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples))
        else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(samples)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(samples),
            into: buffer.mutableAudioBufferList
        )
        guard status == noErr else { return nil }
        return buffer
    }
}
