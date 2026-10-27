import AppKit
import AVFoundation
import Combine
import CoreGraphics

/// Used on the main thread. Not annotated `@MainActor` so the menu-bar
/// entry point can construct it without an actor hop.
final class PermissionCenter: ObservableObject {
    enum State: Equatable {
        case unknown
        case granted
        case denied
    }

    enum Kind {
        case microphone
        case screen
    }

    @Published private(set) var microphone: State = .unknown
    @Published private(set) var screenGranted = false

    var isReady: Bool {
        microphone == .granted && screenGranted
    }

    func refresh() {
        microphone = Self.microphoneState()
        screenGranted = CGPreflightScreenCaptureAccess()
    }

    func requestMicrophone() async -> Bool {
        let granted: Bool
        if #available(macOS 14.0, *) {
            granted = await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { allowed in
                    continuation.resume(returning: allowed)
                }
            }
        } else {
            granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { allowed in
                    continuation.resume(returning: allowed)
                }
            }
        }
        refresh()
        return granted
    }

    /// Shows the system screen-recording consent UI. Granting it usually does
    /// not take effect until the process is relaunched.
    @discardableResult
    func requestScreenCapture() -> Bool {
        let granted = CGRequestScreenCaptureAccess()
        refresh()
        return granted
    }

    func openSettings(_ kind: Kind) {
        let candidates: [String]
        switch kind {
        case .microphone:
            candidates = [
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone",
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
            ]
        case .screen:
            candidates = [
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture",
                "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            ]
        }
        for string in candidates {
            guard let url = URL(string: string) else { continue }
            if NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    private static func microphoneState() -> State {
        if #available(macOS 14.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted:
                return .granted
            case .denied:
                return .denied
            case .undetermined:
                return .unknown
            @unknown default:
                return .unknown
            }
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .granted
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            return .unknown
        @unknown default:
            return .unknown
        }
    }
}
