import Combine
import Foundation
import ScreenCaptureKit

/// One app the user can include in system-audio capture.
struct SystemAudioApp: Equatable, Sendable {
    var bundleIdentifier: String
    var displayName: String
}

/// What `SystemAudioCapture` should put in the ScreenCaptureKit filter.
enum SystemAudioTarget: Equatable, Sendable {
    /// Every shareable app except MeetingRecorder. This is the pre-picker behavior.
    case allOtherApplications
    /// Only these bundle IDs. An empty list is a refusal, not a silent widening.
    case applications([SystemAudioApp])
}

struct SystemAudioStartReport: Equatable, Sendable {
    var includedNames: [String]
    var skippedNames: [String]
}

struct ResolvedSystemAudio: Equatable, Sendable {
    var bundleIDs: [String]
    var report: SystemAudioStartReport
}

/// Pure matching rules shared by the picker and the capture start path.
enum SystemAudioSelection {
    static func resolve(
        requested: [SystemAudioApp],
        runningBundleIDs: Set<String>,
        ownBundleID: String?
    ) -> Result<ResolvedSystemAudio, RecorderError> {
        if requested.isEmpty || requested.allSatisfy({ $0.bundleIdentifier.isEmpty }) {
            return .failure(.noAudioAppsSelected)
        }

        var bundleIDs: [String] = []
        var includedNames: [String] = []
        var skippedNames: [String] = []
        var seen = Set<String>()

        for app in requested {
            let identifier = app.bundleIdentifier
            let name = app.displayName.isEmpty ? identifier : app.displayName
            if identifier.isEmpty || identifier == ownBundleID {
                if !name.isEmpty, !skippedNames.contains(name) {
                    skippedNames.append(name)
                }
                continue
            }
            guard seen.insert(identifier).inserted else { continue }
            if runningBundleIDs.contains(identifier) {
                bundleIDs.append(identifier)
                includedNames.append(name)
            } else if !skippedNames.contains(name) {
                skippedNames.append(name)
            }
        }

        guard !bundleIDs.isEmpty else {
            return .failure(.audioAppsUnavailable(skippedNames.joined(separator: "、")))
        }
        return .success(ResolvedSystemAudio(
            bundleIDs: bundleIDs,
            report: SystemAudioStartReport(includedNames: includedNames, skippedNames: skippedNames)
        ))
    }
}

struct AudioSourceRow: Identifiable, Equatable {
    let bundleIdentifier: String
    let title: String
    let running: Bool

    var id: String { bundleIdentifier }
}

enum AudioSourceSection: String, CaseIterable {
    case selected = "已选"
    case favorites = "常用"
    case other = "其他"
}

/// Menu-bar selection for which apps' system audio to capture.
///
/// Missing `selectedBundleIDs` means the WeChat defaults. A stored empty array
/// means the user cleared the list and start must refuse until they pick again.
/// `captureAllApplications` stays off until the user turns on「全部应用」.
final class CapturePreferences: ObservableObject {
    struct CatalogApp: Equatable {
        var bundleIdentifier: String
        var title: String
    }

    static let catalog: [CatalogApp] = [
        CatalogApp(bundleIdentifier: "com.tencent.xinWeChat", title: "微信"),
        CatalogApp(bundleIdentifier: "com.tencent.WeWorkMac", title: "企业微信"),
        CatalogApp(bundleIdentifier: "com.electron.lark", title: "飞书"),
        CatalogApp(bundleIdentifier: "com.bytedance.macos.feishu", title: "飞书"),
        CatalogApp(bundleIdentifier: "us.zoom.xos", title: "Zoom"),
        CatalogApp(bundleIdentifier: "com.microsoft.teams2", title: "Microsoft Teams"),
        CatalogApp(bundleIdentifier: "com.microsoft.teams", title: "Microsoft Teams（经典版）"),
        CatalogApp(bundleIdentifier: "com.google.Chrome", title: "Google Chrome"),
        CatalogApp(bundleIdentifier: "com.apple.Safari", title: "Safari"),
        CatalogApp(bundleIdentifier: "com.microsoft.edgemac", title: "Microsoft Edge")
    ]

    /// Running apps only, grouped for the picker. Selected-but-not-running apps
    /// stay in `selectedBundleIDs` for start refusal / skip logic, but do not
    /// take a list row.
    var groupedRows: [(section: AudioSourceSection, rows: [AudioSourceRow])] {
        let catalogIDs = Set(Self.catalog.map { $0.bundleIdentifier })
        let runningRows = rows.filter(\.running)
        let selectedRows = runningRows
            .filter { selectedBundleIDs.contains($0.bundleIdentifier) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        let favoriteRows = Self.catalog.compactMap { item -> AudioSourceRow? in
            guard !selectedBundleIDs.contains(item.bundleIdentifier) else { return nil }
            return runningRows.first { $0.bundleIdentifier == item.bundleIdentifier }
        }
        let otherRows = runningRows
            .filter {
                !selectedBundleIDs.contains($0.bundleIdentifier) &&
                !catalogIDs.contains($0.bundleIdentifier)
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

        var groups: [(section: AudioSourceSection, rows: [AudioSourceRow])] = []
        if !selectedRows.isEmpty {
            groups.append((section: .selected, rows: selectedRows))
        }
        if !favoriteRows.isEmpty {
            groups.append((section: .favorites, rows: favoriteRows))
        }
        if !otherRows.isEmpty {
            groups.append((section: .other, rows: otherRows))
        }
        return groups
    }

    /// Selected apps that are not currently shareable / running — kept for start
    /// logic, surfaced as a one-line hint rather than list rows.
    var selectedButNotRunningNames: [String] {
        let runningIDs = Set(rows.filter(\.running).map(\.bundleIdentifier))
        return selectedBundleIDs
            .filter { !runningIDs.contains($0) }
            .map { displayName(for: $0) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static let defaultBundleIDs = ["com.tencent.xinWeChat", "com.tencent.WeWorkMac"]

    /// Window-server chrome. These are not meeting audio sources; 「全部应用」 still includes them.
    static let pickerHiddenBundleIDs: Set<String> = [
        "com.apple.dock",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.WindowManager",
        "com.apple.SystemUIServer",
        "com.apple.loginwindow",
        "com.apple.screensaver",
        "com.apple.Spotlight",
        "com.apple.screencaptureui",
        "com.apple.universalcontrol"
    ]

    private enum Keys {
        static let captureAll = "systemAudio.captureAllApplications"
        static let selected = "systemAudio.selectedBundleIDs"
    }

    @Published private(set) var captureAllApplications: Bool
    @Published private(set) var selectedBundleIDs: Set<String>
    @Published private(set) var rows: [AudioSourceRow] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var listNote: String?

    private let defaults: UserDefaults
    private var discoveredNames: [String: String] = [:]
    private var refreshGeneration = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.object(forKey: Keys.captureAll) == nil {
            captureAllApplications = false
        } else {
            captureAllApplications = defaults.bool(forKey: Keys.captureAll)
        }
        if let stored = defaults.stringArray(forKey: Keys.selected) {
            selectedBundleIDs = Set(stored.filter { !$0.isEmpty })
        } else {
            selectedBundleIDs = Set(Self.defaultBundleIDs)
            defaults.set(Self.defaultBundleIDs, forKey: Keys.selected)
        }
        rebuildRows()
    }

    func makeTarget() -> SystemAudioTarget {
        if captureAllApplications {
            return .allOtherApplications
        }
        let apps = selectedBundleIDs.sorted().map { identifier in
            SystemAudioApp(bundleIdentifier: identifier, displayName: displayName(for: identifier))
        }
        return .applications(apps)
    }

    /// Empty multi-select with「全部应用」off. Nil when start may proceed to ScreenCaptureKit.
    func startRefusalMessage() -> String? {
        guard !captureAllApplications, selectedBundleIDs.isEmpty else { return nil }
        return RecorderError.noAudioAppsSelected.message
    }

    func setCaptureAllApplications(_ enabled: Bool) {
        captureAllApplications = enabled
        defaults.set(enabled, forKey: Keys.captureAll)
    }

    func setSelected(_ bundleIdentifier: String, isOn: Bool) {
        if isOn {
            selectedBundleIDs.insert(bundleIdentifier)
        } else {
            selectedBundleIDs.remove(bundleIdentifier)
        }
        defaults.set(selectedBundleIDs.sorted(), forKey: Keys.selected)
        rebuildRows()
    }

    func isSelected(_ bundleIdentifier: String) -> Bool {
        selectedBundleIDs.contains(bundleIdentifier)
    }

    func refreshRunningApplications() {
        refreshGeneration += 1
        let generation = refreshGeneration
        isRefreshing = true
        Task { @MainActor in
            let loaded: [SystemAudioCapture.ShareableApplication]
            let note: String?
            do {
                loaded = try await SystemAudioCapture.shareableApplications()
                note = nil
            } catch {
                loaded = []
                note = "还不能列出正在运行的应用。请先允许屏幕录制，完全退出并重新打开本应用。下面的常用应用仍可预先勾选。"
            }
            guard generation == self.refreshGeneration else { return }
            var names: [String: String] = [:]
            for app in loaded {
                let identifier = app.bundleIdentifier
                guard !identifier.isEmpty else { continue }
                let trimmed = app.applicationName.trimmingCharacters(in: .whitespacesAndNewlines)
                if names[identifier] == nil {
                    names[identifier] = trimmed.isEmpty ? identifier : trimmed
                }
            }
            self.discoveredNames = names
            self.listNote = note
            self.rebuildRows()
            self.isRefreshing = false
        }
    }

    private func displayName(for bundleIdentifier: String) -> String {
        if let title = Self.catalog.first(where: { $0.bundleIdentifier == bundleIdentifier })?.title {
            return title
        }
        if let discovered = discoveredNames[bundleIdentifier], !discovered.isEmpty {
            return discovered
        }
        return bundleIdentifier
    }

    private func rebuildRows() {
        let own = Bundle.main.bundleIdentifier
        var running: [String: String] = [:]
        for (identifier, name) in discoveredNames {
            guard identifier != own, !Self.pickerHiddenBundleIDs.contains(identifier) else { continue }
            running[identifier] = name
        }

        var built: [AudioSourceRow] = []
        var seen = Set<String>()
        for item in Self.catalog {
            seen.insert(item.bundleIdentifier)
            built.append(AudioSourceRow(
                bundleIdentifier: item.bundleIdentifier,
                title: item.title,
                running: running[item.bundleIdentifier] != nil
            ))
        }

        var extras = Set(running.keys)
        for identifier in selectedBundleIDs where identifier != own && !Self.pickerHiddenBundleIDs.contains(identifier) {
            extras.insert(identifier)
        }
        extras.subtract(seen)

        let ordered = extras.sorted { lhs, rhs in
            displayName(for: lhs).localizedStandardCompare(displayName(for: rhs)) == .orderedAscending
        }
        for identifier in ordered {
            built.append(AudioSourceRow(
                bundleIdentifier: identifier,
                title: displayName(for: identifier),
                running: running[identifier] != nil
            ))
        }
        rows = built
    }
}
