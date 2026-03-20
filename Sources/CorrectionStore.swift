import Foundation

/// A single correction entry: what we inserted vs what the user finalized.
struct CorrectionEntry: Codable, Sendable {
    let id: String
    let timestamp: Date
    let rawText: String
    let insertedText: String
    let userFinalText: String
    let quality: Double
    let appBundleID: String
    let appName: String
    let metadata: [String: String]?
}

/// A semantic diff extracted from a correction entry for training pipelines.
struct SemanticDiff: Codable, Sendable {
    let id: String
    let timestamp: Date
    let before: String
    let after: String
    let appBundleID: String
}

/// Persists corrections to ~/.we/corrections.jsonl and semantic diffs to
/// ~/.we/semantic-diffs.jsonl. Provides query interface for AlternativeSwap.
final class CorrectionStore: @unchecked Sendable {
    static let shared = CorrectionStore()

    private let correctionWriter: JSONLWriter
    private let diffWriter: JSONLWriter

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        correctionWriter = JSONLWriter(
            fileURL: home.appendingPathComponent(".we/corrections.jsonl")
        )
        diffWriter = JSONLWriter(
            fileURL: home.appendingPathComponent(".we/semantic-diffs.jsonl")
        )
    }

    /// Track recent saves for dedup (rawText -> timestamp).
    private let recentLock = NSLock()
    private var recentSaves: [(text: String, time: Date)] = []

    /// Save a correction entry and export its semantic diff.
    /// Automatically filters out garbage data before writing.
    func save(_ entry: CorrectionEntry) {
        // Skip unchanged text.
        guard entry.insertedText != entry.userFinalText else { return }

        // Skip low quality (likely capture noise).
        guard entry.quality >= 0.4 else {
            DebugLog.log(.correction, "Skipped low quality entry (\(String(format: "%.2f", entry.quality)))")
            return
        }

        let final = entry.userFinalText

        // Skip degenerate text: repeated characters from capture bugs.
        // Catches both 4x repeats (aaaa) and doubled-char sequences (ggeemmiinnii).
        if hasDegenerate(final) {
            DebugLog.log(.correction, "Skipped degenerate entry (repeated chars)")
            return
        }

        // Skip truncation-only changes (user just deleted trailing text, not a real correction).
        if entry.insertedText.hasPrefix(final) && final.count < entry.insertedText.count {
            DebugLog.log(.correction, "Skipped truncation-only entry (deleted \(entry.insertedText.count - final.count) trailing chars)")
            return
        }

        // Skip if final text has garbage appended (pinyin leak from IME or function key codes).
        if final.hasPrefix(entry.insertedText) && final.count > entry.insertedText.count {
            let extra = String(final.dropFirst(entry.insertedText.count))
            let cleaned = extra.filter { !$0.isWhitespace && !Self.isFunctionKeyChar($0) }
            if cleaned.count < 10 && cleaned.allSatisfy({ $0.isASCII }) {
                DebugLog.log(.correction, "Skipped IME garbage append: \"\(cleaned)\"")
                return
            }
        }

        // Skip if final text contains macOS function key characters (arrow keys, etc).
        if final.unicodeScalars.contains(where: { Self.isFunctionKeyScalar($0) }) {
            DebugLog.log(.correction, "Skipped entry with function key chars")
            return
        }

        // Dedup: skip if same rawText was saved within the last 60 seconds.
        recentLock.lock()
        let now = Date()
        recentSaves.removeAll { now.timeIntervalSince($0.time) > 60 }
        let isDuplicate = recentSaves.contains { $0.text == entry.rawText }
        if !isDuplicate {
            recentSaves.append((text: entry.rawText, time: now))
        }
        recentLock.unlock()

        if isDuplicate {
            DebugLog.log(.correction, "Skipped duplicate entry (same rawText within 60s)")
            return
        }

        correctionWriter.append(entry)
        DebugLog.log(.correction, "Saved correction: raw=\(entry.rawText.count) chars, inserted=\(entry.insertedText.count) chars, final=\(entry.userFinalText.count) chars, quality=\(String(format: "%.2f", entry.quality))")

        // Export semantic diff.
        let diff = SemanticDiff(
            id: entry.id,
            timestamp: entry.timestamp,
            before: entry.insertedText,
            after: entry.userFinalText,
            appBundleID: entry.appBundleID
        )
        diffWriter.append(diff)
    }

    /// Load all correction entries (used by AlternativeSwap to build correction map).
    /// Filters out known-bad patterns from historical data.
    func loadHistory() -> [CorrectionEntry] {
        var seen = Set<String>()
        return correctionWriter.readAll(as: CorrectionEntry.self).filter { entry in
            let final = entry.userFinalText
            // Filter degenerate text.
            guard !hasDegenerate(final) else { return false }
            // Filter function key chars.
            guard !final.unicodeScalars.contains(where: { Self.isFunctionKeyScalar($0) }) else { return false }
            // Filter truncation-only.
            guard !(entry.insertedText.hasPrefix(final)
                    && final.count < entry.insertedText.count) else { return false }
            // Filter IME garbage append.
            if final.hasPrefix(entry.insertedText) && final.count > entry.insertedText.count {
                let cleaned = String(final.dropFirst(entry.insertedText.count))
                    .filter { !$0.isWhitespace && !Self.isFunctionKeyChar($0) }
                if cleaned.count < 10 && cleaned.allSatisfy({ $0.isASCII }) { return false }
            }
            // Dedup by rawText (keep first occurrence only).
            guard seen.insert(entry.rawText).inserted else { return false }
            return true
        }
    }

    /// Load all semantic diffs (used by training pipeline export).
    /// Filters out diffs with degenerate text.
    func loadDiffs() -> [SemanticDiff] {
        var seen = Set<String>()
        return diffWriter.readAll(as: SemanticDiff.self).filter { diff in
            guard !hasDegenerate(diff.after) else { return false }
            guard !diff.after.unicodeScalars.contains(where: { Self.isFunctionKeyScalar($0) }) else { return false }
            guard !(diff.before.hasPrefix(diff.after) && diff.after.count < diff.before.count) else { return false }
            if diff.after.hasPrefix(diff.before) && diff.after.count > diff.before.count {
                let cleaned = String(diff.after.dropFirst(diff.before.count))
                    .filter { !$0.isWhitespace && !Self.isFunctionKeyChar($0) }
                if cleaned.count < 10 && cleaned.allSatisfy({ $0.isASCII }) { return false }
            }
            guard seen.insert(diff.before).inserted else { return false }
            return true
        }
    }

    /// Load corrections filtered by app bundle ID.
    func corrections(for bundleID: String) -> [CorrectionEntry] {
        loadHistory().filter { $0.appBundleID == bundleID }
    }

    // MARK: - Degenerate Detection

    /// Detect degenerate text from capture bugs.
    /// Catches: 4x single-char repeats (aaaa), doubled-char sequences (ggeemmiinnii),
    /// and mixed patterns.
    private func hasDegenerate(_ text: String) -> Bool {
        guard text.count >= 4 else { return false }

        // Pattern 1: any single character repeated 4+ times consecutively.
        let chars = Array(text)
        for i in 0..<(chars.count - 3) {
            if chars[i] == chars[i+1] && chars[i+1] == chars[i+2] && chars[i+2] == chars[i+3] {
                return true
            }
        }

        // Pattern 2: doubled-char sequence (e.g. "ggeemmiinnii" = 6+ consecutive doubled pairs).
        // Scan for runs of (XY) where X == Y.
        var consecutiveDoubles = 0
        var i = 0
        while i < chars.count - 1 {
            if chars[i] == chars[i+1] {
                consecutiveDoubles += 1
                i += 2
                if consecutiveDoubles >= 3 {
                    return true
                }
            } else {
                consecutiveDoubles = 0
                i += 1
            }
        }

        return false
    }

    /// Check if a character is a macOS function key code (U+F700-U+F8FF private use area).
    private static func isFunctionKeyChar(_ c: Character) -> Bool {
        c.unicodeScalars.allSatisfy { isFunctionKeyScalar($0) }
    }

    private static func isFunctionKeyScalar(_ s: Unicode.Scalar) -> Bool {
        s.value >= 0xF700 && s.value <= 0xF8FF
    }
}
