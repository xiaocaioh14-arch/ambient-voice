import Foundation

struct VoiceHistoryEntry: Codable, Sendable {
    let sessionID: String
    let timestamp: Date
    let rawText: String
    let l1Text: String
    let polishedText: String?
    let appBundleID: String
    let appName: String
    let wordCount: Int
    let duration: TimeInterval
    let polished: Bool
}

final class VoiceHistory: Sendable {
    static let shared = VoiceHistory()

    private let writer: JSONLWriter

    private init() {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".we/voice-history.jsonl")
        writer = JSONLWriter(fileURL: url)
    }

    func save(entry: VoiceHistoryEntry) {
        writer.append(entry)
    }

    func loadHistory() -> [VoiceHistoryEntry] {
        writer.readAll(as: VoiceHistoryEntry.self)
    }
}
