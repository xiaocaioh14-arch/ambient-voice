import Foundation

/// A single transcribed segment in a meeting.
struct MeetingSegment: Codable, Sendable {
    let id: String
    let timestamp: TimeInterval  // Offset from meeting start
    let text: String
    let speakerIndex: Int
    let isFinal: Bool

    init(timestamp: TimeInterval, text: String, speakerIndex: Int, isFinal: Bool = true) {
        self.id = UUID().uuidString
        self.timestamp = timestamp
        self.text = text
        self.speakerIndex = speakerIndex
        self.isFinal = isFinal
    }
}

/// A complete meeting record.
struct Meeting: Codable, Sendable {
    let id: String
    let startDate: Date
    var endDate: Date?
    var segments: [MeetingSegment]
    var audioChunkPaths: [String]

    init() {
        self.id = UUID().uuidString
        self.startDate = Date()
        self.endDate = nil
        self.segments = []
        self.audioChunkPaths = []
    }

    /// Meeting duration in seconds.
    var duration: TimeInterval {
        let end = endDate ?? Date()
        return end.timeIntervalSince(startDate)
    }

    /// Format duration as MM:SS.
    var formattedDuration: String {
        let total = Int(duration)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// Protocol for speaker tracking strategies.
/// Default implementation uses RMS energy-based silence detection.
/// Can be replaced with more sophisticated speaker diarization in the future.
protocol SpeakerTracker {
    mutating func processSilence(durationMs: Int) -> Bool  // Returns true if speaker changed
    var currentSpeakerIndex: Int { get }
}

/// Simple silence-based speaker tracker.
/// When silence exceeds the threshold, assumes speaker changed.
struct SilenceBasedSpeakerTracker: SpeakerTracker {
    let silenceThresholdMs: Int
    private(set) var currentSpeakerIndex: Int = 0

    init(silenceThresholdMs: Int = 1500) {
        self.silenceThresholdMs = silenceThresholdMs
    }

    mutating func processSilence(durationMs: Int) -> Bool {
        if durationMs >= silenceThresholdMs {
            currentSpeakerIndex += 1
            return true
        }
        return false
    }
}
