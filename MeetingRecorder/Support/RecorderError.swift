import Foundation

/// User-facing failures. `message` is Chinese because the whole UI is Chinese.
enum RecorderError: Error {
    case microphoneDenied
    case screenCaptureDenied
    case noDisplay
    case noMicrophoneDevice
    case noAudioAppsSelected
    case audioAppsUnavailable(String)
    case systemAudioFailed(String)
    case writerFailed(String)
    case interrupted(String)

    var message: String {
        switch self {
        case .microphoneDenied:
            return "还不能使用麦克风。请在「系统设置 → 隐私与安全性 → 麦克风」中允许「会议录音」。"
        case .screenCaptureDenied:
            return "还不能采集系统音频。请在「系统设置 → 隐私与安全性 → 屏幕录制」（较新系统里叫「屏幕与系统音频录制」）中允许「会议录音」，然后完全退出并重新打开本应用。本应用不保存画面。"
        case .noDisplay:
            return "没有找到可用的显示器，系统音频无法开始。"
        case .noMicrophoneDevice:
            return "没有可用的麦克风输入。请确认麦克风已连接，并且没有被其他应用独占。"
        case .noAudioAppsSelected:
            return "还没有选择要采集系统音频的应用，录音没有开始。请勾选微信或其他应用；若要采集除本应用以外的所有应用，请打开「全部应用」。"
        case .audioAppsUnavailable(let names):
            if names.isEmpty {
                return "所选应用都还没在运行，或系统还不能共享它们的窗口。请先打开要录音的应用，再开始录音。"
            }
            return "所选应用都还没在运行，或系统还不能共享它们的窗口：\(names)。请先打开要录音的应用，再开始录音。"
        case .systemAudioFailed(let detail):
            return "系统音频没有启动：\(detail)"
        case .writerFailed(let detail):
            return "音频文件写入失败：\(detail)"
        case .interrupted(let detail):
            return "录音中断，已尽量保存已录内容。\(detail)"
        }
    }

    static func skippedApplicationsNotice(_ names: [String]) -> String {
        let list = names.joined(separator: "、")
        return "这些应用当前没有在运行或还不能共享，已跳过：\(list)。其余已选应用会继续录音。"
    }

    static func message(from error: Error) -> String {
        if let known = error as? RecorderError {
            return known.message
        }
        let ns = error as NSError
        if ns.code == -3801 || ns.code == -3803 {
            return RecorderError.screenCaptureDenied.message
        }
        if ns.code == -3818 {
            return RecorderError.systemAudioFailed(ns.localizedDescription).message
        }
        let blob = "\(ns.domain) \(ns.localizedDescription)".lowercased()
        if blob.contains("declin") || blob.contains("not authorized") || blob.contains("permission") || blob.contains("tcc") {
            return RecorderError.screenCaptureDenied.message
        }
        if ns.localizedDescription.isEmpty {
            return "录音失败（\(ns.domain) \(ns.code)）。"
        }
        return "录音失败：\(ns.localizedDescription)"
    }
}
