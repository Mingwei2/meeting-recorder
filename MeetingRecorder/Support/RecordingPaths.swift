import AppKit
import Foundation

enum RecordingPaths {
    /// Shared with the Homebrew fallback so both paths land in one folder.
    static var directory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("MeetingRecordings", isDirectory: true)
    }

    static func makeDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// `会议录音_yyyyMMdd_HHmmss.m4a` in the Mac's current time zone.
    static func newFileURL(now: Date = Date()) throws -> URL {
        try makeDirectory()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let stamp = formatter.string(from: now)
        var url = directory.appendingPathComponent("会议录音_\(stamp).m4a")
        if FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("会议录音_\(stamp)_\(Int(now.timeIntervalSince1970)).m4a")
        }
        return url
    }

    static func fileSize(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        if let size = values?.fileSize {
            return Int64(size)
        }
        return nil
    }

    static func format(byteCount: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: byteCount)
    }

    static func openFolder() {
        NSWorkspace.shared.open(directory)
    }

    static func reveal(_ url: URL) {
        reveal([url])
    }

    static func reveal(_ urls: [URL]) {
        let files = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !files.isEmpty else {
            openFolder()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting(files)
    }
}
