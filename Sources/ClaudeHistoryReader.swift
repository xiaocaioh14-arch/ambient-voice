import Foundation

/// Reads Claude Code's session JSONL to extract the user's final submitted text.
///
/// When CorrectionCapture fails to read the terminal AX buffer (TUI apps like
/// Claude Code), this reader provides a fallback: read the last user message
/// from Claude Code's session log, which contains the exact text the user submitted.
///
/// Session files live at: ~/.claude/projects/{project-path-encoded}/{sessionId}.jsonl
enum ClaudeHistoryReader {

    private static let claudeProjectsDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
    }()

    /// Find the most recent user text message submitted after `since`.
    ///
    /// Scans all project session files modified recently, reads the last few
    /// user messages, and returns the one closest in time to our injection.
    static func lastUserMessage(after since: Date, maxDelay: TimeInterval = 60) -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: claudeProjectsDir.path) else { return nil }

        // Find session JSONL files modified within the last 2 minutes.
        let cutoff = since.addingTimeInterval(-10)
        guard let sessionFiles = recentSessionFiles(modifiedAfter: cutoff) else { return nil }

        var bestMatch: (text: String, timestamp: Date)?

        for fileURL in sessionFiles {
            guard let lines = tailLines(of: fileURL, count: 30) else { continue }

            for line in lines.reversed() {
                guard let data = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      json["type"] as? String == "user",
                      let timestampStr = json["timestamp"] as? String,
                      let timestamp = parseISO8601(timestampStr) else { continue }

                // Must be after our injection time.
                guard timestamp > since, timestamp.timeIntervalSince(since) < maxDelay else { continue }

                // Extract user text (not tool results).
                guard let text = extractUserText(from: json) else { continue }
                guard !text.isEmpty else { continue }

                if bestMatch == nil || timestamp < bestMatch!.timestamp {
                    bestMatch = (text, timestamp)
                }
            }
        }

        if let match = bestMatch {
            DebugLog.log(.correction, "Claude history: found user message \(String(format: "%.1f", match.timestamp.timeIntervalSince(since)))s after injection: \"\(match.text.prefix(60))...\"")
        }

        return bestMatch?.text
    }

    // MARK: - Private

    /// Find .jsonl files under ~/.claude/projects/ modified after cutoff.
    private static func recentSessionFiles(modifiedAfter cutoff: Date) -> [URL]? {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(
            at: claudeProjectsDir, includingPropertiesForKeys: nil
        ) else { return nil }

        var results: [URL] = []
        for projectDir in projectDirs {
            guard let files = try? fm.contentsOfDirectory(
                at: projectDir, includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { continue }

            for file in files {
                guard file.pathExtension == "jsonl" else { continue }
                guard let attrs = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
                      let modDate = attrs.contentModificationDate,
                      modDate > cutoff else { continue }
                results.append(file)
            }
        }

        return results.isEmpty ? nil : results
    }

    /// Read the last N lines of a file efficiently.
    private static func tailLines(of url: URL, count: Int) -> [String]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let content = String(data: data.suffix(min(data.count, 50_000)), encoding: .utf8) else { return nil }
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        return Array(lines.suffix(count))
    }

    /// Extract user text content from a session JSONL entry.
    /// Returns nil for tool results (which have toolUseResult field).
    private static func extractUserText(from json: [String: Any]) -> String? {
        // Skip tool result messages.
        if json["toolUseResult"] != nil { return nil }

        guard let message = json["message"] as? [String: Any] else { return nil }
        let content = message["content"]

        if let text = content as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let contentArray = content as? [[String: Any]] {
            for item in contentArray {
                if item["type"] as? String == "text",
                   let text = item["text"] as? String {
                    return text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }

        return nil
    }

    private static func parseISO8601(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? {
            let basic = ISO8601DateFormatter()
            basic.formatOptions = [.withInternetDateTime]
            return basic.date(from: string)
        }()
    }
}
