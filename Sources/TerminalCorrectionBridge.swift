import Foundation

/// Bridge between WE and the shell for terminal correction capture.
///
/// When WE injects text into a terminal app, it writes a pending record
/// to ~/.we/pending-terminal.json. A zsh preexec hook reads this file,
/// compares with the actual command the user executed, and writes
/// corrections to ~/.we/corrections.jsonl if they differ.
///
/// This bypasses the AX buffer limitation in terminal apps like Ghostty.
enum TerminalCorrectionBridge {

    private static let pendingURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".we/pending-terminal.json")
    }()

    /// Write a pending terminal injection for the shell hook to pick up.
    ///
    /// Called by CorrectionCapture when the target app is a terminal
    /// and prompt detection fails.
    static func writePending(insertedText: String, rawText: String, app: AppIdentity) {
        let pending: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "insertedText": insertedText,
            "rawText": rawText,
            "appBundleID": app.bundleID,
            "appName": app.appName,
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: pending, options: [.prettyPrinted]) else {
            DebugLog.log(.correction, "Failed to serialize pending terminal capture", level: .warning)
            return
        }

        do {
            try data.write(to: pendingURL, options: .atomic)
            DebugLog.log(.correction, "Pending terminal capture written: \"\(insertedText)\"")
        } catch {
            DebugLog.log(.correction, "Failed to write pending terminal capture: \(error)", level: .warning)
        }
    }

    /// Clear the pending file (called when a non-terminal capture succeeds).
    static func clearPending() {
        try? FileManager.default.removeItem(at: pendingURL)
    }

    /// Import corrections written by the shell hook.
    ///
    /// The shell hook writes to ~/.we/terminal-corrections.jsonl.
    /// This method reads new entries and imports them into CorrectionStore.
    /// Called periodically or at pipeline start.
    static func importShellCorrections() {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".we/terminal-corrections.jsonl")

        guard FileManager.default.fileExists(atPath: url.path) else { return }

        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }

        guard !lines.isEmpty else { return }

        var imported = 0
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rawText = json["rawText"] as? String,
                  let insertedText = json["insertedText"] as? String,
                  let userFinalText = json["userFinalText"] as? String,
                  let quality = json["quality"] as? Double,
                  let appBundleID = json["appBundleID"] as? String,
                  let appName = json["appName"] as? String else { continue }

            DebugLog.log(.correction, "Shell hook: inserted=\"\(insertedText.prefix(30))...\" final=\"\(userFinalText.prefix(30))...\" quality=\(String(format: "%.2f", quality))")

            let entry = CorrectionEntry(
                id: json["id"] as? String ?? UUID().uuidString,
                timestamp: Date(),
                rawText: rawText,
                insertedText: insertedText,
                userFinalText: userFinalText,
                quality: quality,
                appBundleID: appBundleID,
                appName: appName,
                metadata: ["captureMode": "shell-hook"]
            )
            CorrectionStore.shared.save(entry)
            imported += 1
        }

        if imported > 0 {
            DebugLog.log(.correction, "Imported \(imported) terminal corrections from shell hook")
            // Truncate the file after import
            try? "".write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
