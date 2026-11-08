import AppKit
import Darwin
import SwiftUI

struct PopoverView: View {
    @ObservedObject var session: MeetingSession
    @ObservedObject var permissions: PermissionCenter
    @ObservedObject var preferences: CapturePreferences

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                header
                if let banner = session.banner {
                    Label(banner, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(bannerColor)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(bannerColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
                recordingControls
                Divider()
                AudioSourcePicker(preferences: preferences, isEditable: session.phase == .idle)
                if !permissions.isReady {
                    Divider()
                    permissionSection
                }
            }
            .padding(16)

            VStack(spacing: 10) {
                if let lastFile = session.lastFile {
                    recentRecording(lastFile)
                    Divider()
                }
                footer
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.primary.opacity(0.025))
        }
        .frame(width: 360, alignment: .leading)
        .fixedSize(horizontal: true, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("会议录音")
                    .font(.system(size: 18, weight: .semibold))
                Text("麦克风 + 系统音频 · 本地 M4A")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                Label(statusTitle, systemImage: session.phase == .recording ? "record.circle" : "circle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .labelStyle(StatusLabelStyle())
                    .foregroundStyle(statusColor)
                Button {
                    permissions.openSettings(permissions.microphone == .denied ? .microphone : .screen)
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("权限设置")
                .help(permissions.isReady ? "权限已就绪 · 打开权限设置" : "打开权限设置")
            }
            .padding(.top, 5)
        }
    }

    private var statusTitle: String {
        switch session.phase {
        case .idle: return permissions.isReady ? "就绪" : "待授权"
        case .starting: return "准备中"
        case .recording: return "录音中"
        case .stopping: return "保存中"
        }
    }

    private var statusColor: Color {
        switch session.phase {
        case .recording: return Color(nsColor: .systemRed)
        case .idle: return permissions.isReady ? .secondary : Color(nsColor: .systemOrange)
        case .starting, .stopping: return .secondary
        }
    }

    private var bannerColor: Color {
        if let banner = session.banner,
           banner.contains("已跳过"),
           !banner.contains("还没有收到系统音频") {
            return Color(nsColor: .systemOrange)
        }
        return Color(nsColor: .systemRed)
    }

    private var recordingControls: some View {
        VStack(spacing: 14) {
            if session.phase != .idle {
                Text(session.elapsedText)
                    .font(.system(size: 36, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("录音时长 \(session.elapsedText)")
                    .padding(.top, 2)
            }

            Button {
                session.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: session.phase == .recording ? "stop.fill" : "record.circle")
                        .font(.system(size: 15, weight: .semibold))
                    Text(session.recordButtonTitle)
                        .font(.system(size: 14, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 30)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle)
            .controlSize(.large)
            .tint(session.phase == .recording ? Color(nsColor: .systemRed) : .accentColor)
            .keyboardShortcut("r", modifiers: .command)
            .help("\(session.recordButtonTitle)（⌘R）")
            .disabled(session.phase == .starting || session.phase == .stopping)

            if session.phase == .recording {
                HStack(spacing: 20) {
                    LevelMeter(title: "麦克风", symbol: "mic", level: session.micLevel)
                    LevelMeter(title: "系统音频", symbol: "speaker.wave.2", level: session.systemLevel)
                }
            }
        }
    }

    private var permissionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("录音前，允许两项权限")
                .font(.system(size: 12, weight: .semibold))
            PermissionLine(
                title: "麦克风",
                symbol: "mic",
                detail: "录制你的声音",
                granted: permissions.microphone == .granted,
                actionTitle: permissions.microphone == .denied ? "打开设置" : "允许",
                action: {
                    if permissions.microphone == .denied {
                        permissions.openSettings(.microphone)
                    } else {
                        Task { await permissions.requestMicrophone() }
                    }
                }
            )
            PermissionLine(
                title: "屏幕录制",
                symbol: "rectangle.on.rectangle",
                detail: "仅采集声音，不保存画面",
                granted: permissions.screenGranted,
                actionTitle: "允许",
                action: {
                    _ = permissions.requestScreenCapture()
                    if !permissions.screenGranted {
                        permissions.openSettings(.screen)
                    }
                }
            )
            if !permissions.screenGranted {
                Text("允许后请退出并重开应用。系统设置中可能显示为「屏幕与系统音频录制」。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("重新检查") { permissions.refresh() }
                Spacer()
                Button("系统设置") {
                    permissions.openSettings(permissions.screenGranted ? .microphone : .screen)
                }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
        }
    }

    private func recentRecording(_ url: URL) -> some View {
        Button {
            RecordingPaths.reveal(url)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "waveform")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text("最近录音")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(url.lastPathComponent)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(session.savedSummary ?? "在访达中显示最近一次录音")
        .accessibilityLabel("在访达中显示最近录音，\(url.lastPathComponent)")
    }

    private var footer: some View {
        HStack {
            Button {
                RecordingPaths.openFolder()
            } label: {
                Label("录音文件夹", systemImage: "folder")
            }
            .help("打开录音文件夹")
            Spacer()
            Button("退出") { NSApp.terminate(nil) }
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12))
    }
}

private struct AudioSourcePicker: View {
    @ObservedObject var preferences: CapturePreferences
    let isEditable: Bool
    @State private var searchText = ""
    @State private var showsOtherApplications = false
    @FocusState private var searchFocused: Bool

    private var query: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var groups: [(section: AudioSourceSection, rows: [AudioSourceRow])] {
        preferences.groupedRows.compactMap { group in
            let rows = group.rows.filter {
                query.isEmpty || $0.title.localizedStandardContains(query) ||
                $0.bundleIdentifier.localizedStandardContains(query)
            }
            return rows.isEmpty ? nil : (section: group.section, rows: rows)
        }
    }

    private var listHeight: CGFloat {
        guard !groups.isEmpty else { return 96 }
        let height = groups.reduce(CGFloat(0)) { result, group in
            let collapsed = group.section == .other && !showsOtherApplications && query.isEmpty
            return result + 24 + (collapsed ? 0 : CGFloat(group.rows.count) * 32)
        }
        return min(180, height)
    }

    var body: some View {
        if isEditable {
            picker
        } else {
            captureSummary
        }
    }

    private var captureSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("采集应用")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Label("结束录音后可更改", systemImage: "lock")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if preferences.captureAllApplications {
                Label("全部应用", systemImage: "speaker.wave.2")
                    .font(.system(size: 12))
            } else {
                let selected = preferences.rows.filter { preferences.isSelected($0.bundleIdentifier) }
                HStack(spacing: 8) {
                    ForEach(Array(selected.prefix(3))) { row in
                        ApplicationIcon(bundleIdentifier: row.bundleIdentifier)
                    }
                    Text(selected.map(\.title).joined(separator: "、"))
                        .font(.system(size: 12))
                        .lineLimit(2)
                        .help(selected.map(\.title).joined(separator: "、"))
                }
            }
        }
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("采集应用")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Toggle("全部应用", isOn: Binding(
                    get: { preferences.captureAllApplications },
                    set: { preferences.setCaptureAllApplications($0) }
                ))
                .font(.system(size: 11))
                .toggleStyle(.switch)
                .controlSize(.small)
                .fixedSize()
                Button {
                    preferences.refreshRunningApplications()
                } label: {
                    Group {
                        if preferences.isRefreshing {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 12, weight: .medium))
                        }
                    }
                    .frame(width: 16, height: 16)
                }
                .buttonStyle(.borderless)
                .disabled(preferences.isRefreshing)
                .accessibilityLabel(preferences.isRefreshing ? "正在刷新应用" : "刷新应用列表")
                .help("刷新正在运行的应用")
            }

            if preferences.captureAllApplications {
                Label("采集所有应用的声音，原有勾选会保留。", systemImage: "speaker.wave.2")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 4)
            } else {
                searchField
                ScrollView(.vertical) {
                    if groups.isEmpty {
                        emptyState
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(groups, id: \.section) { group in
                                if group.section == .other && query.isEmpty {
                                    DisclosureGroup(isExpanded: $showsOtherApplications) {
                                        applicationRows(group.rows)
                                    } label: {
                                        groupHeading("其他应用", count: group.rows.count)
                                    }
                                    .font(.system(size: 11))
                                    .tint(.secondary)
                                } else {
                                    groupHeading(group.section.rawValue, count: group.rows.count)
                                    applicationRows(group.rows)
                                }
                            }
                        }
                    }
                }
                .frame(height: listHeight)
                .scrollIndicators(.visible)

                if preferences.selectedBundleIDs.isEmpty {
                    Label("至少选择一个应用，才能开始录音", systemImage: "info.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else if !preferences.selectedButNotRunningNames.isEmpty {
                    Text("未运行：\(preferences.selectedButNotRunningNames.joined(separator: "、"))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help("已选但未运行：\(preferences.selectedButNotRunningNames.joined(separator: "、"))")
                }
            }

            if let note = preferences.listNote, !note.isEmpty {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(note)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索应用", text: $searchText)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .accessibilityLabel("搜索采集应用")
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("清除搜索")
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(
            searchFocused ? Color.accentColor : Color(nsColor: .separatorColor).opacity(0.45),
            lineWidth: searchFocused ? 2 : 1
        ))
    }

    private var emptyState: some View {
        VStack(spacing: 7) {
            Image(systemName: query.isEmpty ? "app.dashed" : "magnifyingglass")
                .font(.system(size: 20, weight: .light))
            Text(query.isEmpty ? (preferences.isRefreshing ? "正在查找运行中的应用…" : "没有可采集的应用") : "没有匹配的应用")
                .font(.system(size: 12, weight: .medium))
            Text(query.isEmpty ? "打开需要录音的应用，再刷新列表" : "试试应用名称，或清除搜索")
                .font(.system(size: 11))
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .frame(height: 96)
    }

    private func groupHeading(_ title: String, count: Int) -> some View {
        HStack(spacing: 5) {
            Text(title)
            Text("\(count)").monospacedDigit()
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .frame(height: 24, alignment: .center)
    }

    private func applicationRows(_ rows: [AudioSourceRow]) -> some View {
        ForEach(rows) { row in
            Toggle(isOn: Binding(
                get: { preferences.isSelected(row.bundleIdentifier) },
                set: { preferences.setSelected(row.bundleIdentifier, isOn: $0) }
            )) {
                HStack(spacing: 8) {
                    ApplicationIcon(bundleIdentifier: row.bundleIdentifier)
                    Text(row.title)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .toggleStyle(.checkbox)
            .padding(.horizontal, 8)
            .frame(height: 32)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                preferences.isSelected(row.bundleIdentifier) ? Color.accentColor.opacity(0.08) : .clear,
                in: RoundedRectangle(cornerRadius: 7)
            )
            .help(row.title)
        }
    }
}

private struct ApplicationIcon: View {
    let bundleIdentifier: String
    @State private var icon: NSImage?

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else {
                Image(systemName: "app.dashed")
                    .resizable()
                    .foregroundStyle(.secondary)
                    .padding(3)
            }
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
        .onAppear {
            if let runningIcon = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first?.icon {
                icon = runningIcon
            } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
                icon = NSWorkspace.shared.icon(forFile: url.path)
            }
        }
    }
}

private struct StatusLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 6))
            configuration.title
        }
    }
}

private struct PermissionLine: View {
    let title: String
    let symbol: String
    let detail: String
    let granted: Bool
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color(nsColor: .systemGreen))
                    .accessibilityLabel("\(title)已允许")
            } else {
                Button(actionTitle, action: action)
                    .controlSize(.small)
            }
        }
    }
}

private struct LevelMeter: View {
    let title: String
    let symbol: String
    let level: Float

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: proxy.size.width * CGFloat(visual))
                }
            }
            .frame(height: 4)
            .accessibilityLabel("\(title)音量")
            .accessibilityValue("\(Int(visual * 100))%")
        }
    }

    /// Map roughly −50 dBFS…0 dBFS onto the bar so speech is visible.
    private var visual: Double {
        let clamped = max(level, 0.000_01)
        let db = 20.0 * log10(Double(clamped))
        return min(1, max(0, (db + 50) / 50))
    }
}
