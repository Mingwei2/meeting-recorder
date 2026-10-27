import Combine
import Foundation

/// Used on the main thread. See `PermissionCenter`.
final class MeetingSession: ObservableObject {
    enum Phase: Equatable {
        case idle
        case starting
        case recording
        case stopping
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var systemLevel: Float = 0
    @Published private(set) var banner: String?
    @Published private(set) var savedSummary: String?
    @Published private(set) var lastFile: URL?

    var onChange: (() -> Void)?

    private let permissions: PermissionCenter
    private var engine: RecordingEngine?
    private var chain: Task<Void, Never>?
    private var stopRequested = false
    private var startedAt: Date?

    init(permissions: PermissionCenter) {
        self.permissions = permissions
    }

    var isBusy: Bool {
        phase != .idle || engine != nil
    }

    var elapsedText: String {
        let total = max(0, Int(elapsed))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    var recordButtonTitle: String {
        switch phase {
        case .idle:
            return "开始录音"
        case .starting:
            return "正在开始…"
        case .recording:
            return "停止录音"
        case .stopping:
            return "正在保存…"
        }
    }

    func toggle() {
        switch phase {
        case .idle:
            enqueueStart()
        case .starting, .recording:
            enqueueStop()
        case .stopping:
            break
        }
    }

    func tick() {
        guard phase == .recording, let startedAt else { return }
        elapsed = Date().timeIntervalSince(startedAt)
        onChange?()
    }

    func stopForQuit() async {
        stopRequested = true
        await enqueueStop().value
    }

    private func enqueueStart() {
        guard phase == .idle else { return }
        stopRequested = false
        phase = .starting
        onChange?()
        let previous = chain
        let task = Task { @MainActor in
            await previous?.value
            await self.runStart()
        }
        chain = task
    }

    @discardableResult
    private func enqueueStop() -> Task<Void, Never> {
        stopRequested = true
        let previous = chain
        let task = Task { @MainActor in
            await previous?.value
            await self.runStop(clearBanner: false)
        }
        chain = task
        return task
    }

    private func runStart() async {
        guard !stopRequested else { return }
        banner = nil
        phase = .starting
        elapsed = 0
        micLevel = 0
        systemLevel = 0
        onChange?()

        do {
            try await ensurePermissions()
            guard !stopRequested else {
                phase = .idle
                onChange?()
                return
            }
            let url = try RecordingPaths.newFileURL()
            let engine = RecordingEngine()
            engine.onLevels = { [weak self] levels in
                Task { @MainActor in
                    guard let self else { return }
                    self.micLevel = levels.microphone
                    self.systemLevel = levels.system
                    if levels.systemFrames > 0, self.banner?.contains("还没有收到系统音频") == true {
                        self.banner = nil
                        self.onChange?()
                    }
                }
            }
            engine.onNotice = { [weak self] text in
                Task { @MainActor in
                    guard let self, self.banner == nil else { return }
                    self.banner = text
                    self.onChange?()
                }
            }
            engine.onFatal = { [weak self] error in
                Task { @MainActor in
                    self?.banner = RecorderError.message(from: error)
                    self?.enqueueStop()
                }
            }
            try await engine.start(outputURL: url)
            if stopRequested {
                _ = await engine.stop()
                remember(url)
                phase = .idle
                onChange?()
                return
            }
            self.engine = engine
            startedAt = Date()
            phase = .recording
            onChange?()
        } catch {
            if !stopRequested {
                banner = RecorderError.message(from: error)
            }
            phase = .idle
            startedAt = nil
            onChange?()
        }
    }

    private func runStop(clearBanner: Bool) async {
        let engine = self.engine
        self.engine = nil
        if engine == nil {
            phase = .idle
            startedAt = nil
            stopRequested = false
            onChange?()
            return
        }
        phase = .stopping
        onChange?()
        let url = await engine.stop()
        remember(url)
        phase = .idle
        startedAt = nil
        elapsed = 0
        micLevel = 0
        systemLevel = 0
        stopRequested = false
        if clearBanner {
            banner = nil
        }
        onChange?()
    }

    private func ensurePermissions() async throws {
        permissions.refresh()
        if permissions.microphone != .granted {
            let granted = await permissions.requestMicrophone()
            if !granted {
                throw RecorderError.microphoneDenied
            }
        }
        permissions.refresh()
        if !permissions.screenGranted {
            _ = permissions.requestScreenCapture()
            permissions.refresh()
            if !permissions.screenGranted {
                throw RecorderError.screenCaptureDenied
            }
        }
    }

    private func remember(_ url: URL?) {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        lastFile = url
        if let size = RecordingPaths.fileSize(at: url) {
            savedSummary = "已保存 \(url.lastPathComponent) · \(RecordingPaths.format(byteCount: size))"
        } else {
            savedSummary = "已保存 \(url.lastPathComponent)"
        }
    }
}
