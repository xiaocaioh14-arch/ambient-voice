import Foundation

/// Structured logging utility.
/// Writes timestamped, categorized log lines to ~/.we/debug.log with automatic rotation.
///
/// Usage:
///   DebugLog.log(.voice, "Session started for \(bundleID)")
///   DebugLog.shared.log(.voice, "Session started")
final class DebugLog: Sendable {
    static let shared = DebugLog()

    // MARK: - Types

    enum Category: String, Sendable {
        case hotKey         = "WE:HotKey"
        case voice          = "WE:Voice"
        case correction     = "CorrectionCapture"
        case pipeline       = "WE:Pipeline"
        case model          = "WE:Model"
        case config         = "WE:Config"
        case permission     = "WE:Permission"
        case screenContext  = "WE:ScreenContext"
        case meeting        = "WE:Meeting"
    }

    enum Level: Int, Sendable, Comparable {
        case debug = 0
        case info = 1
        case warning = 2
        case error = 3

        var label: String {
            switch self {
            case .debug:   return "DEBUG"
            case .info:    return "INFO"
            case .warning: return "WARN"
            case .error:   return "ERROR"
            }
        }

        static func < (lhs: Level, rhs: Level) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    // MARK: - Configuration

    private static let maxFileSize: UInt64 = 10 * 1024 * 1024  // 10 MB
    private static let rotatedSuffix = ".1"

    private static let logURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".we")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("debug.log")
    }()

    /// Serial queue for thread-safe file writes and date formatting.
    private let queue = DispatchQueue(label: "we.debuglog", qos: .utility)

    // MARK: - Init

    init() {}

    // MARK: - Public API

    /// Convenience static method so callers can write `DebugLog.log(...)`.
    static func log(_ category: Category, _ message: String, level: Level = .info) {
        shared.log(category, message, level: level)
    }

    /// Write a structured log line.
    func log(_ category: Category, _ message: String, level: Level = .info) {
        let date = Date()
        queue.async {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            let timestamp = formatter.string(from: date)
            let line = "\(timestamp) [\(level.label)] [\(category.rawValue)] \(message)\n"
            Self.writeLine(line)
        }
    }

    // MARK: - File I/O (called on serial queue)

    private static func writeLine(_ line: String) {
        let url = logURL
        let fm = FileManager.default

        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }

        // Rotate if oversized
        if let attrs = try? fm.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? UInt64,
           size > maxFileSize {
            let rotated = url.appendingPathExtension(rotatedSuffix)
            try? fm.removeItem(at: rotated)
            try? fm.moveItem(at: url, to: rotated)
            fm.createFile(atPath: url.path, contents: nil)
        }

        guard let data = line.data(using: .utf8),
              let handle = try? FileHandle(forWritingTo: url) else { return }
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    }
}
