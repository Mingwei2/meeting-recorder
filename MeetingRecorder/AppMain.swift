import AppKit
import Foundation

/// Menu-bar app. `NSApplication.delegate` is unowned, so `Holder` keeps it alive.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var session: MeetingSession?
    private var permissions: PermissionCenter?
    private var statusBar: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        try? RecordingPaths.makeDirectory()

        let permissions = PermissionCenter()
        let session = MeetingSession(permissions: permissions)
        let statusBar = StatusBarController(session: session, permissions: permissions)
        self.permissions = permissions
        self.session = session
        self.statusBar = statusBar
        statusBar.install()
        permissions.refresh()
        if !permissions.isReady {
            DispatchQueue.main.async {
                statusBar.showPopover()
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        permissions?.refresh()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let session, session.isBusy else {
            return .terminateNow
        }
        Task { @MainActor in
            await session.stopForQuit()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

private enum Holder {
    static var delegate: AppDelegate?
}

@main
enum AppMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        Holder.delegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
