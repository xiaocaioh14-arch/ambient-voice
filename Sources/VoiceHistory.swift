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
    let audioFilePath: String?

    enum CodingKeys: String, CodingKey {
        case sessionID, timestamp, rawText, l1Text, polishedText
        case appBundleID, appName, wordCount, duration, polished
        case audioFilePath = "audio_file_path"
    }
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
