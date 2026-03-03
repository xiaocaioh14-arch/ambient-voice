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
final class CorrectionStore: Sendable {
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

    /// Save a correction entry and export its semantic diff.
    func save(_ entry: CorrectionEntry) {
        correctionWriter.append(entry)

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
    func loadHistory() -> [CorrectionEntry] {
        correctionWriter.readAll(as: CorrectionEntry.self)
    }

    /// Load all semantic diffs (used by training pipeline export).
    func loadDiffs() -> [SemanticDiff] {
        diffWriter.readAll(as: SemanticDiff.self)
    }

    /// Load corrections filtered by app bundle ID.
    func corrections(for bundleID: String) -> [CorrectionEntry] {
        loadHistory().filter { $0.appBundleID == bundleID }
    }
}
