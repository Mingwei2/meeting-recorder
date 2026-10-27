import Foundation

/// User-facing failures. `message` is Chinese because the whole UI is Chinese.
enum RecorderError: Error {
    case microphoneDenied
    case screenCaptureDenied
    case noDisplay
    case noMicrophoneDevice
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
        case .systemAudioFailed(let detail):
            return "系统音频没有启动：\(detail)"
        case .writerFailed(let detail):
            return "音频文件写入失败：\(detail)"
        case .interrupted(let detail):
            return "录音中断，已尽量保存已录内容。\(detail)"
        }
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
