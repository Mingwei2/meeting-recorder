import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import os
import ScreenCaptureKit

/// ScreenCaptureKit audio capture for a chosen set of apps.
///
/// The content filter is the list macOS uses for the per-window "being shared"
/// badge. `allOtherApplications` includes every other app. `applications`
/// includes only the requested bundle IDs, still excluding this process.
/// Audio follows that application list, including a window that lives on another display.
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
    struct ShareableApplication: Equatable, Sendable {
        var bundleIdentifier: String
        var applicationName: String
    }

    /// Same shareable-content query the stream uses, so the picker and the filter agree.
    static func shareableApplications() async throws -> [ShareableApplication] {
        let content = try await loadShareableContent()
        return content.applications.map { app in
            ShareableApplication(bundleIdentifier: app.bundleIdentifier, applicationName: app.applicationName)
        }
    }
    var onPCM: ((AVAudioPCMBuffer) -> Void)?
    var onInterruption: ((Error) -> Void)?

    private let audioQueue = DispatchQueue(label: "local.meetingrecorder.system-audio", qos: .userInitiated)
    private let videoQueue = DispatchQueue(label: "local.meetingrecorder.video-discard", qos: .background)
    private let converter = PCMConverter()
    private var stream: SCStream?
    private var armed: ArmedCapture?
    private var intentionalStop = false
    private let log = Logger(subsystem: "local.meetingrecorder.app", category: "system-audio")

    /// Resolves the filter and refuses an empty or unmatched selection.
    /// Does not start the stream, so a refusal does not badge any window.
    func validate(_ target: SystemAudioTarget) async throws {
        armed = try await makePlan(for: target)
    }

    func cancelValidation() {
        armed = nil
    }

    /// Starts the stream prepared by `validate`. Selected apps never fall back to every other app.
    func startValidated() async throws -> SystemAudioStartReport {
        intentionalStop = false
        guard let armed else {
            throw RecorderError.systemAudioFailed("系统音频还没有准备好。")
        }
        self.armed = nil

        switch armed.filter {
        case .allOtherApplications:
            return try await startAllOtherApplications(armed)
        case .selected(let applications, let report):
            do {
                let created = try makeSelectedStream(applications: applications, display: armed.display, configuration: armed.configuration)
                try await start(created)
            } catch {
                stream = nil
                throw map(error)
            }
            let includedLabel = report.includedNames.joined(separator: ", ")
            let skippedLabel = report.skippedNames.joined(separator: ", ")
            log.info("System audio stream started for \(includedLabel, privacy: .public). Skipped: \(skippedLabel, privacy: .public).")
            return report
        }
    }

    private struct ArmedCapture {
        enum Filter {
            case allOtherApplications
            case selected([SCRunningApplication], SystemAudioStartReport)
        }

        var content: SCShareableContent
        var display: SCDisplay
        var configuration: SCStreamConfiguration
        var filter: Filter
    }

    private func makePlan(for target: SystemAudioTarget) async throws -> ArmedCapture {
        switch target {
        case .applications(let apps) where apps.isEmpty:
            throw RecorderError.noAudioAppsSelected
        default:
            break
        }

        let content = try await Self.loadShareableContent()
        guard let display = Self.preferredDisplay(in: content.displays) else {
            throw RecorderError.noDisplay
        }
        let configuration = Self.makeConfiguration()

        switch target {
        case .allOtherApplications:
            return ArmedCapture(
                content: content,
                display: display,
                configuration: configuration,
                filter: .allOtherApplications
            )
        case .applications(let apps):
            let running = Set(content.applications.map(\.bundleIdentifier))
            let resolved = try SystemAudioSelection.resolve(
                requested: apps,
                runningBundleIDs: running,
                ownBundleID: Bundle.main.bundleIdentifier
            ).get()
            let own = Bundle.main.bundleIdentifier
            let included = content.applications.filter {
                resolved.bundleIDs.contains($0.bundleIdentifier) && $0.bundleIdentifier != own
            }
            guard !included.isEmpty else {
                throw RecorderError.audioAppsUnavailable(resolved.report.skippedNames.joined(separator: "、"))
            }
            return ArmedCapture(
                content: content,
                display: display,
                configuration: configuration,
                filter: .selected(included, resolved.report)
            )
        }
    }

    private func startAllOtherApplications(_ armed: ArmedCapture) async throws -> SystemAudioStartReport {
        do {
            let created = try makeAllApplicationsStream(content: armed.content, display: armed.display, configuration: armed.configuration)
            try await start(created)
            log.info("System audio stream started (all other applications).")
            return SystemAudioStartReport(includedNames: [], skippedNames: [])
        } catch {
            log.error("All-application filter failed: \(error.localizedDescription, privacy: .public). Retrying display filter.")
            let created = try makeExcludingSelfStream(content: armed.content, display: armed.display, configuration: armed.configuration)
            do {
                try await start(created)
            } catch {
                stream = nil
                throw map(error)
            }
            log.info("System audio stream started (display filter excluding this app).")
            return SystemAudioStartReport(includedNames: [], skippedNames: [])
        }
    }

    func stop() async {
        intentionalStop = true
        armed = nil
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

    private func makeAllApplicationsStream(
        content: SCShareableContent,
        display: SCDisplay,
        configuration: SCStreamConfiguration
    ) throws -> SCStream {
        let bundleID = Bundle.main.bundleIdentifier
        let mine = content.applications.filter { $0.bundleIdentifier == bundleID }
        let others = content.applications.filter { $0.bundleIdentifier != bundleID }
        let filter: SCContentFilter
        if others.isEmpty {
            filter = SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: [])
        } else {
            // Audio follows the application list, so a window on another display is included.
            filter = SCContentFilter(display: display, including: others, exceptingWindows: [])
        }
        return SCStream(filter: filter, configuration: configuration, delegate: self)
    }

    /// Fallback for「全部应用」only. This is the display-wide filter and badges the other windows.
    private func makeExcludingSelfStream(
        content: SCShareableContent,
        display: SCDisplay,
        configuration: SCStreamConfiguration
    ) throws -> SCStream {
        let bundleID = Bundle.main.bundleIdentifier
        let mine = content.applications.filter { $0.bundleIdentifier == bundleID }
        let filter = SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: [])
        return SCStream(filter: filter, configuration: configuration, delegate: self)
    }

    /// Selected apps only. Never widens to every other app when this filter fails.
    private func makeSelectedStream(
        applications: [SCRunningApplication],
        display: SCDisplay,
        configuration: SCStreamConfiguration
    ) throws -> SCStream {
        let bundleID = Bundle.main.bundleIdentifier
        let included = applications.filter { $0.bundleIdentifier != bundleID }
        if included.isEmpty {
            throw RecorderError.audioAppsUnavailable("")
        }
        let filter = SCContentFilter(display: display, including: included, exceptingWindows: [])
        return SCStream(filter: filter, configuration: configuration, delegate: self)
    }

    private static func loadShareableContent() async throws -> SCShareableContent {
        // Enumerating shareable content can itself present macOS consent UI.
        // Opening or refreshing our popover must only check authorization;
        // PermissionCenter requests it after an explicit user action.
        guard CGPreflightScreenCaptureAccess() else {
            throw RecorderError.screenCaptureDenied
        }
        return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
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
        let format = AVAudioFormat(cmAudioFormatDescription: formatDescription)
        guard samples > 0,
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
