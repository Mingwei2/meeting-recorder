import AppKit
import Darwin
import SwiftUI

struct PopoverView: View {
    @ObservedObject var session: MeetingSession
    @ObservedObject var permissions: PermissionCenter
    @ObservedObject var preferences: CapturePreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let banner = session.banner {
                Text(banner)
                    .font(.system(size: 12))
                    .foregroundStyle(bannerColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(bannerColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }
            if session.phase == .recording || session.phase == .starting {
                Text(session.elapsedText)
                    .font(.system(size: 32, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            Button {
                session.toggle()
            } label: {
                Text(session.recordButtonTitle)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(session.phase == .recording ? Color(nsColor: .systemRed) : Color(nsColor: .controlAccentColor))
            .disabled(session.phase == .starting || session.phase == .stopping)

            if session.phase == .recording {
                VStack(alignment: .leading, spacing: 8) {
                    LevelMeter(title: "麦克风", level: session.micLevel)
                    LevelMeter(title: "系统音频", level: session.systemLevel)
                }
            }

            audioSourceCard
            permissionCard

            if let summary = session.savedSummary {
                Text(summary)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(summary)
            }

            footer
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
        .fixedSize(horizontal: true, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            preferences.refreshRunningApplications()
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

    private var audioSourceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("采集应用")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(preferences.isRefreshing ? "刷新中…" : "刷新") {
                    preferences.refreshRunningApplications()
                }
                .controlSize(.small)
                .disabled(session.phase != .idle || preferences.isRefreshing)
            }

            Toggle(isOn: Binding(
                get: { preferences.captureAllApplications },
                set: { preferences.setCaptureAllApplications($0) }
            )) {
                Text("全部应用")
                    .font(.system(size: 13, weight: .medium))
            }
            .toggleStyle(.switch)
            .disabled(session.phase != .idle)

            if preferences.captureAllApplications {
                Text("已采集全部应用（勾选会保留）")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(preferences.groupedRows.enumerated()), id: \.offset) { group in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(group.element.section.rawValue)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary)
                                ForEach(group.element.rows) { row in
                                    audioSourceRow(row)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 4)
                }
                .frame(height: 180)

                if preferences.selectedBundleIDs.isEmpty {
                    Text("至少勾选一个应用")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(nsColor: .systemOrange))
                } else if !preferences.selectedButNotRunningNames.isEmpty {
                    Text("已选未运行：\(preferences.selectedButNotRunningNames.joined(separator: "、"))")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .help(preferences.selectedButNotRunningNames.joined(separator: "、"))
                }

                if preferences.groupedRows.isEmpty {
                    Text("没有检测到可采集的运行中应用，点「刷新」再试")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            if let listNote = preferences.listNote, !listNote.isEmpty {
                Text(listNote)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(listNote)
            }
        }
        .padding(12)
        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
    }

    private func audioSourceRow(_ row: AudioSourceRow) -> some View {
        Toggle(isOn: Binding(
            get: { preferences.isSelected(row.bundleIdentifier) },
            set: { preferences.setSelected(row.bundleIdentifier, isOn: $0) }
        )) {
            Text(row.title)
                .font(.system(size: 12))
                .lineLimit(1)
        }
        .toggleStyle(.checkbox)
        .disabled(session.phase != .idle || preferences.captureAllApplications)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("会议录音")
                .font(.system(size: 18, weight: .semibold))
            Text("麦克风 + 系统音频 · 本地 m4a")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private var permissionCard: some View {
        Group {
            if permissions.isReady {
                HStack {
                    Text("权限已就绪")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("设置") { permissions.openSettings(.screen) }
                        .buttonStyle(.link)
                        .controlSize(.small)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("需要权限")
                        .font(.system(size: 13, weight: .semibold))
                    PermissionLine(
                        title: "麦克风",
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
                        detail: "采集应用声音，不保存画面",
                        granted: permissions.screenGranted,
                        actionTitle: permissions.screenGranted ? "已允许" : "允许",
                        action: {
                            if permissions.screenGranted {
                                permissions.refresh()
                            } else {
                                _ = permissions.requestScreenCapture()
                                if !permissions.screenGranted {
                                    permissions.openSettings(.screen)
                                }
                            }
                        }
                    )
                    if !permissions.screenGranted {
                        Text("允许后请退出并重开应用；设置中可能显示为「屏幕与系统音频录制」。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Button("重新检查") { permissions.refresh() }
                            .controlSize(.small)
                        Spacer()
                        Button("系统设置") {
                            permissions.openSettings(permissions.screenGranted ? .microphone : .screen)
                        }
                        .controlSize(.small)
                    }
                }
                .padding(12)
                .background(
                    Color(nsColor: .quaternaryLabelColor).opacity(0.25),
                    in: RoundedRectangle(cornerRadius: 10)
                )
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button("打开录音文件夹") {
                RecordingPaths.openFolder()
            }
            .buttonStyle(.link)
            if let lastFile = session.lastFile {
                Button("显示最近") {
                    RecordingPaths.reveal(lastFile)
                }
                .buttonStyle(.link)
            }
            Spacer(minLength: 8)
            Button("退出") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.link)
            .foregroundStyle(.secondary)
        }
    }
}

private struct PermissionLine: View {
    let title: String
    let detail: String
    let granted: Bool
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(granted ? "已允许" : "未允许")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(granted ? Color(nsColor: .systemGreen) : Color(nsColor: .systemOrange))
            if !granted {
                Button(actionTitle, action: action)
                    .controlSize(.small)
            }
        }
    }
}

private struct LevelMeter: View {
    let title: String
    let level: Float

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12))
                .frame(width: 64, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(nsColor: .separatorColor))
                    Capsule()
                        .fill(Color(nsColor: .controlAccentColor))
                        .frame(width: max(4, proxy.size.width * CGFloat(visual)))
                }
            }
            .frame(height: 8)
        }
    }

    /// Map roughly −50 dBFS…0 dBFS onto the bar so speech is visible.
    private var visual: Double {
        let clamped = max(level, 0.000_01)
        let db = 20.0 * log10(Double(clamped))
        return min(1, max(0, (db + 50) / 50))
    }
}
