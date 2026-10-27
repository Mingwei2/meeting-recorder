import AppKit
import SwiftUI

final class StatusBarController: NSObject {
    private let session: MeetingSession
    private let permissions: PermissionCenter
    private let preferences: CapturePreferences
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var timer: Timer?
    private let idleImage: NSImage
    private let recordingImage: NSImage

    init(session: MeetingSession, permissions: PermissionCenter, preferences: CapturePreferences) {
        self.session = session
        self.permissions = permissions
        self.preferences = preferences
        idleImage = Self.makeIdleImage()
        recordingImage = Self.makeRecordingImage()
        super.init()
    }

    func install() {
        guard let button = statusItem.button else { return }
        button.imagePosition = .imageLeading
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)

        let host = NSHostingController(rootView: PopoverView(session: session, permissions: permissions, preferences: preferences))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true

        session.onChange = { [weak self] in
            self?.render()
        }
        render()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.session.tick()
                self?.render()
            }
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func showPopover() {
        togglePopover(nil)
        if !popover.isShown {
            // toggle closed it if a stray click raced; force open
            openPopover()
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            openPopover()
        }
    }

    private func openPopover() {
        guard let button = statusItem.button else { return }
        permissions.refresh()
        preferences.refreshRunningApplications()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func render() {
        guard let button = statusItem.button else { return }
        switch session.phase {
        case .recording:
            button.image = recordingImage
            button.attributedTitle = NSAttributedString(string: " " + session.elapsedText, attributes: Self.recordingAttributes)
            button.setAccessibilityLabel("正在录音 \(session.elapsedText)")
        case .starting, .stopping:
            button.image = recordingImage
            let title = session.phase == .starting ? " …" : " 保存"
            button.attributedTitle = NSAttributedString(string: title, attributes: Self.recordingAttributes)
            button.setAccessibilityLabel(session.recordButtonTitle)
        case .idle:
            button.image = idleImage
            button.attributedTitle = NSAttributedString(string: "")
            button.setAccessibilityLabel("会议录音")
        }
    }

    private static let recordingAttributes: [NSAttributedString.Key: Any] = [
        .foregroundColor: NSColor.systemRed,
        .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
    ]

    private static func makeIdleImage() -> NSImage {
        let image = NSImage(systemSymbolName: "mic", accessibilityDescription: "会议录音") ?? NSImage()
        image.isTemplate = true
        return image
    }

    private static func makeRecordingImage() -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5)).fill()
            NSColor.white.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 5.5, dy: 5.5)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}
