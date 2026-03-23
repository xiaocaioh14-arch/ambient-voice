import Foundation
import Speech

/// Exports meeting transcripts to Markdown format.
/// Format: **[MM:SS]** Speaker N: text
/// Files saved to ~/.we/meetings/{id}/transcript.md
enum MeetingExporter {

    /// Export a meeting to Markdown and save to disk.
    ///
    /// - Parameter meeting: The meeting to export.
    /// - Returns: The file path of the exported Markdown, or nil on failure.
    @discardableResult
    static func export(_ meeting: Meeting) -> String? {
        guard !meeting.segments.isEmpty else {
            DebugLog.log(.meeting, "No segments to export for meeting \(meeting.id)")
            return nil
        }

        let markdown = generateMarkdown(meeting)

        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".we/meetings/\(meeting.id)")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            DebugLog.log(.meeting, "Failed to create meeting directory: \(error)", level: .error)
            return nil
        }

        let url = dir.appendingPathComponent("transcript.md")
        do {
            try markdown.write(to: url, atomically: true, encoding: .utf8)
            DebugLog.log(.meeting, "Exported meeting \(meeting.id) to \(url.path)")
            return url.path
        } catch {
            DebugLog.log(.meeting, "Failed to write transcript: \(error)", level: .error)
            return nil
        }
    }

    /// Generate Markdown content from a meeting.
    static func generateMarkdown(_ meeting: Meeting) -> String {
        var lines: [String] = []

        // Header
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let dateStr = formatter.string(from: meeting.startDate)

        lines.append("# Meeting — \(dateStr)")
        lines.append("")
        lines.append("Duration: \(meeting.formattedDuration)")
        lines.append("Segments: \(meeting.segments.count)")
        lines.append("")
        lines.append("---")
        lines.append("")

        // Segments
        for segment in meeting.segments where segment.isFinal {
            let timestamp = formatTimestamp(segment.timestamp)
            let speaker = "Speaker \(segment.speakerIndex + 1)"
            lines.append("**[\(timestamp)]** \(speaker): \(segment.text)")
            lines.append("")
        }

        // Footer
        if !meeting.audioChunkPaths.isEmpty {
            lines.append("---")
            lines.append("")
            lines.append("Audio chunks: \(meeting.audioChunkPaths.count)")
            for path in meeting.audioChunkPaths {
                let filename = URL(fileURLWithPath: path).lastPathComponent
                lines.append("- `\(filename)`")
            }
        }

        return lines.joined(separator: "\n")
    }

    private static func formatTimestamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    // MARK: - Offline Transcription

    /// Transcribe audio chunks from a meeting directory and export transcript.
    /// Use when real-time recognition failed but audio was saved.
    ///
    /// - Parameter meetingID: The meeting UUID string.
    /// - Returns: The file path of the exported Markdown, or nil on failure.
    @discardableResult
    static func transcribeOffline(meetingID: String) async -> String? {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".we/meetings/\(meetingID)")

        guard FileManager.default.fileExists(atPath: dir.path) else {
            DebugLog.log(.meeting, "Meeting directory not found: \(meetingID)")
            return nil
        }

        // Find audio chunks sorted by name
        let chunks = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?.filter {
            $0.pathExtension == "caf" || $0.pathExtension == "wav" || $0.pathExtension == "m4a"
        }.sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []

        guard !chunks.isEmpty else {
            DebugLog.log(.meeting, "No audio chunks found for meeting \(meetingID)")
            return nil
        }

        DebugLog.log(.meeting, "Transcribing \(chunks.count) chunks offline for meeting \(meetingID)")

        let locale = Locale(identifier: "zh-Hans")
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            DebugLog.log(.meeting, "Speech recognizer unavailable for offline transcription", level: .error)
            return nil
        }

        var segments: [MeetingSegment] = []
        var runningOffset: TimeInterval = 0

        for chunk in chunks {
            DebugLog.log(.meeting, "Transcribing chunk: \(chunk.lastPathComponent)")

            let chunkSegments = await transcribeFile(chunk, recognizer: recognizer)
            for seg in chunkSegments {
                let meetingSegment = MeetingSegment(
                    timestamp: runningOffset + seg.timestamp,
                    text: seg.text,
                    speakerIndex: 0,
                    isFinal: true
                )
                segments.append(meetingSegment)
            }
            // Advance offset by the end of the last segment in this chunk
            if let lastSeg = chunkSegments.last {
                runningOffset += lastSeg.timestamp + lastSeg.duration
            }
        }

        guard !segments.isEmpty else {
            DebugLog.log(.meeting, "Offline transcription produced no text for meeting \(meetingID)")
            return nil
        }

        // Merge consecutive segments into sentence-level blocks
        let merged = mergeSegments(segments)

        // Build export struct matching the original meeting directory
        let mirrorMeeting = MeetingForExport(
            id: meetingID,
            startDate: Date(),
            segments: merged,
            audioChunkPaths: chunks.map(\.path),
            formattedDuration: formatTimestamp(runningOffset)
        )

        let markdown = generateOfflineMarkdown(mirrorMeeting)
        let url = dir.appendingPathComponent("transcript.md")
        do {
            try markdown.write(to: url, atomically: true, encoding: .utf8)
            DebugLog.log(.meeting, "Offline transcript saved: \(url.path)")
            return url.path
        } catch {
            DebugLog.log(.meeting, "Failed to write offline transcript: \(error)", level: .error)
            return nil
        }
    }

    /// List all meeting IDs that have audio but no transcript.
    static func pendingMeetings() -> [String] {
        let baseDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".we/meetings")
        guard let dirs = try? FileManager.default.contentsOfDirectory(at: baseDir, includingPropertiesForKeys: nil) else {
            return []
        }
        return dirs.compactMap { dir -> String? in
            let id = dir.lastPathComponent
            let hasAudio = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
                .contains { ["caf", "wav", "m4a"].contains($0.pathExtension) } ?? false
            let hasTranscript = FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcript.md").path)
            return hasAudio && !hasTranscript ? id : nil
        }
    }

    // MARK: - Private helpers

    /// Thread-safe accumulator for recognition results.
    private final class RecognitionAccumulator: @unchecked Sendable {
        typealias Seg = (timestamp: TimeInterval, duration: TimeInterval, text: String)
        private let lock = NSLock()
        private(set) var segments: [Seg] = []
        private(set) var isDone = false

        func update(_ segs: [Seg]) {
            lock.lock()
            segments = segs
            lock.unlock()
        }

        func markDone() {
            lock.lock()
            isDone = true
            lock.unlock()
        }

        func snapshot() -> (segments: [Seg], isDone: Bool) {
            lock.lock()
            defer { lock.unlock() }
            return (segments, isDone)
        }
    }

    /// Transcribe a single audio file with hard timeout.
    /// SFSpeechRecognizer sometimes never sends isFinal, so we poll and use a stall timeout.
    private static func transcribeFile(_ url: URL, recognizer: SFSpeechRecognizer) async -> [(timestamp: TimeInterval, duration: TimeInterval, text: String)] {
        DebugLog.log(.meeting, "transcribeFile starting for \(url.lastPathComponent)")

        let acc = RecognitionAccumulator()

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = true
        request.taskHint = .dictation

        let task = recognizer.recognitionTask(with: request) { result, error in
            if let result {
                let segs = result.bestTranscription.segments.map {
                    (timestamp: $0.timestamp, duration: $0.duration, text: $0.substring)
                }
                acc.update(segs)

                if result.isFinal {
                    DebugLog.log(.meeting, "Recognition isFinal: \(segs.count) segments")
                    acc.markDone()
                }
            }

            if let error {
                DebugLog.log(.meeting, "Chunk recognition error: \(error.localizedDescription)", level: .warning)
                acc.markDone()
            }
        }

        // Poll until done or stalled (no new segments for 10s) or hard timeout (120s)
        let startTime = Date()
        var lastSegCount = 0
        var lastChangeTime = Date()

        while true {
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2s poll

            let snap = acc.snapshot()

            if snap.isDone {
                DebugLog.log(.meeting, "Chunk done (isFinal/error): \(snap.segments.count) segments")
                return snap.segments
            }

            // Track if segments are still growing
            if snap.segments.count != lastSegCount {
                lastSegCount = snap.segments.count
                lastChangeTime = Date()
                DebugLog.log(.meeting, "Recognition progress: \(lastSegCount) segments")
            }

            // Stall detection: no new segments for 10s
            let stallElapsed = -lastChangeTime.timeIntervalSinceNow
            if stallElapsed >= 10.0 && lastSegCount > 0 {
                DebugLog.log(.meeting, "Recognition stalled (\(Int(stallElapsed))s), returning \(lastSegCount) segments")
                task.cancel()
                return snap.segments
            }

            // Hard timeout: 120s max per chunk
            let totalElapsed = -startTime.timeIntervalSinceNow
            if totalElapsed >= 120.0 {
                DebugLog.log(.meeting, "Recognition hard timeout (120s), returning \(lastSegCount) segments")
                task.cancel()
                return snap.segments
            }
        }
    }

    /// Merge word-level segments into sentence blocks (by punctuation or time gap).
    private static func mergeSegments(_ segments: [MeetingSegment]) -> [MeetingSegment] {
        guard !segments.isEmpty else { return [] }

        var merged: [MeetingSegment] = []
        var currentText = ""
        var currentStart = segments[0].timestamp
        var lastEnd: TimeInterval = 0

        for seg in segments {
            let gap = seg.timestamp - lastEnd
            // Start new block on long pause (>1.5s) or punctuation ending
            if gap > 1.5 && !currentText.isEmpty {
                merged.append(MeetingSegment(
                    timestamp: currentStart,
                    text: currentText.trimmingCharacters(in: .whitespaces),
                    speakerIndex: 0
                ))
                currentText = ""
                currentStart = seg.timestamp
            }
            currentText += seg.text
            lastEnd = seg.timestamp
        }

        if !currentText.isEmpty {
            merged.append(MeetingSegment(
                timestamp: currentStart,
                text: currentText.trimmingCharacters(in: .whitespaces),
                speakerIndex: 0
            ))
        }

        return merged
    }

    /// Lightweight struct for offline export (avoids mutating the original Meeting).
    private struct MeetingForExport {
        let id: String
        let startDate: Date
        let segments: [MeetingSegment]
        let audioChunkPaths: [String]
        let formattedDuration: String
    }

    private static func generateOfflineMarkdown(_ meeting: MeetingForExport) -> String {
        var lines: [String] = []

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let dateStr = formatter.string(from: meeting.startDate)

        lines.append("# Meeting Transcript (Offline) — \(dateStr)")
        lines.append("")
        lines.append("Duration: \(meeting.formattedDuration)")
        lines.append("Segments: \(meeting.segments.count)")
        lines.append("")
        lines.append("---")
        lines.append("")

        for segment in meeting.segments {
            let timestamp = formatTimestamp(segment.timestamp)
            lines.append("**[\(timestamp)]** \(segment.text)")
            lines.append("")
        }

        if !meeting.audioChunkPaths.isEmpty {
            lines.append("---")
            lines.append("")
            lines.append("Audio chunks: \(meeting.audioChunkPaths.count)")
            for path in meeting.audioChunkPaths {
                let filename = URL(fileURLWithPath: path).lastPathComponent
                lines.append("- `\(filename)`")
            }
        }

        return lines.joined(separator: "\n")
    }
}
