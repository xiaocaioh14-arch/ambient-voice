import Foundation
import Speech

struct TranscribedWord {
    let text: String
    let timestamp: TimeInterval
    let duration: TimeInterval
    let confidence: Float
    let alternatives: [String]
}

struct TranscriptionResult {
    let fullText: String
    let words: [TranscribedWord]
    let isFinal: Bool
    let rawSegments: [SFTranscriptionSegment]?
}

final class TranscriptionAccumulator {
    private var words: [TranscribedWord] = []
    private var fullText: String = ""
    private var rawSegments: [SFTranscriptionSegment]?

    func update(from result: SFSpeechRecognitionResult) {
        fullText = result.bestTranscription.formattedString
        words = result.bestTranscription.segments.map { segment in
            TranscribedWord(
                text: segment.substring,
                timestamp: segment.timestamp,
                duration: segment.duration,
                confidence: segment.confidence,
                alternatives: segment.alternativeSubstrings
            )
        }
        rawSegments = result.bestTranscription.segments
    }

    func finalize() -> TranscriptionResult {
        let result = TranscriptionResult(
            fullText: fullText,
            words: words,
            isFinal: true,
            rawSegments: rawSegments
        )
        reset()
        return result
    }

    func reset() {
        words = []
        fullText = ""
        rawSegments = nil
    }
}
