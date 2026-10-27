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
                    .fixedSize(horizontal: false, vertical: true)
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
        VStack(alignment: .leading, spacing: 8) {
            Text("采集哪些应用")
                .font(.system(size: 13, weight: .semibold))
            Text("系统音频仍走屏幕录制。只有勾选的应用窗口会显示正在共享；菜单栏的录制指示可能仍会亮。选了浏览器会包含它的全部窗口和标签页。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(isOn: Binding(
                get: { preferences.captureAllApplications },
                set: { preferences.setCaptureAllApplications($0) }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("全部应用")
                        .font(.system(size: 13, weight: .medium))
                    Text("打开后采集除本应用以外的所有应用，各窗口会重新显示正在共享。默认关闭。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .disabled(session.phase != .idle)

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(preferences.rows) { row in
                        Toggle(isOn: Binding(
                            get: { preferences.isSelected(row.bundleIdentifier) },
                            set: { preferences.setSelected(row.bundleIdentifier, isOn: $0) }
                        )) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(row.title)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Text(row.running ? "运行中" : "未打开")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .disabled(session.phase != .idle || preferences.captureAllApplications)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(height: sourceListHeight)

            if preferences.captureAllApplications {
                Text("当前会采集全部应用。下面的勾选会保留，关掉「全部应用」后再生效。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if preferences.selectedBundleIDs.isEmpty {
                Text("至少勾选一个应用后才能开始录音。")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: .systemOrange))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let listNote = preferences.listNote {
                Text(listNote)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button(preferences.isRefreshing ? "正在读取…" : "刷新正在运行的应用") {
                    preferences.refreshRunningApplications()
                }
                .disabled(preferences.isRefreshing)
                .controlSize(.small)
                Spacer()
            }
        }
        .padding(10)
        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }

    private var sourceListHeight: CGFloat {
        let rows = CGFloat(max(preferences.rows.count, 1))
        return min(140, rows * 28)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("会议录音")
                .font(.system(size: 18, weight: .semibold))
            Text("麦克风 + 系统音频，只写本地 m4a")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(permissions.isReady ? "权限已就绪" : "需要两项权限")
                .font(.system(size: 13, weight: .semibold))
            PermissionLine(
                title: "麦克风",
                detail: "录下你自己的声音",
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
                detail: "采集所选应用的系统音频，不保存画面",
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
                Text("允许屏幕录制后，点「退出」再重新打开。macOS 要等进程重启才生效。系统设置里也可能显示为「屏幕与系统音频录制」。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("重新检查") { permissions.refresh() }
                    .controlSize(.small)
                Spacer()
                Button("打开系统设置") { permissions.openSettings(permissions.screenGranted ? .microphone : .screen) }
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button("打开录音文件夹") {
                RecordingPaths.openFolder()
            }
            .buttonStyle(.link)
            if let lastFile = session.lastFile {
                Button("在访达中显示最近一次") {
                    RecordingPaths.reveal(lastFile)
                }
                .buttonStyle(.link)
            }
            Text("系统音频来自屏幕录制权限，不用安装 BlackHole。默认勾选微信和企业微信。打开「全部应用」后，各窗口都会显示正在共享。文件在「文稿 / MeetingRecordings」。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
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
