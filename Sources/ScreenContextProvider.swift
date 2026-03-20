import Foundation
import AppKit
import ScreenCaptureKit
import Vision

/// Screen context captured at hotkey press time.
struct ScreenContext: Sendable {
    let keywords: [String]
    let captureTimestamp: Date
}

/// Captures the focused window screenshot and extracts keywords via Vision OCR.
/// Used to provide screen context to the voice pipeline for disambiguation.
enum ScreenContextProvider {

    /// Capture the frontmost window and extract keywords via OCR.
    ///
    /// - Parameter config: Screen context configuration.
    /// - Returns: ScreenContext with extracted keywords, or nil on failure.
    static func capture(config: WEConfig.ScreenContextConfig) async -> ScreenContext? {
        guard config.enabled else { return nil }

        let start = Date()
        DebugLog.log(.screenContext, "Starting screen capture")

        do {
            guard let image = try await captureActiveWindow(timeout: config.ocrTimeout) else {
                DebugLog.log(.screenContext, "No active window to capture", level: .warning)
                return nil
            }

            let text = try await recognizeText(in: image, timeout: config.ocrTimeout)
            let keywords = extractKeywords(from: text, maxCount: config.maxKeywords)

            let elapsed = Int(-start.timeIntervalSinceNow * 1000)
            DebugLog.log(.screenContext, "Extracted \(keywords.count) keywords in \(elapsed)ms")

            return ScreenContext(keywords: keywords, captureTimestamp: start)
        } catch {
            DebugLog.log(.screenContext, "Capture failed: \(error)", level: .warning)
            return nil
        }
    }

    // MARK: - Screenshot

    private static func captureActiveWindow(timeout: Double) async throws -> CGImage? {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        // Find the frontmost window of the active application
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = frontApp.processIdentifier

        guard let window = content.windows.first(where: {
            $0.owningApplication?.processID == pid && $0.isOnScreen
        }) else {
            return nil
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width) * 2  // Retina
        config.height = Int(window.frame.height) * 2
        config.showsCursor = false

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )
        return image
    }

    // MARK: - OCR

    private static func recognizeText(in image: CGImage, timeout: Double) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let text = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                continuation.resume(returning: text)
            }

            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: image, options: [:])

            // Run OCR on background thread
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Keyword Extraction

    /// Extract keywords from OCR text:
    /// - English: capitalized words, camelCase tokens
    /// - Chinese: 2-8 character continuous segments
    /// Deduplicates and returns up to maxCount keywords.
    static func extractKeywords(from text: String, maxCount: Int) -> [String] {
        var keywords: [String] = []
        var seen = Set<String>()

        func addUnique(_ word: String) {
            let trimmed = word.trimmingCharacters(in: .punctuationCharacters)
            guard !trimmed.isEmpty, trimmed.count >= 2, !seen.contains(trimmed) else { return }
            seen.insert(trimmed)
            keywords.append(trimmed)
        }

        // Split into segments by whitespace
        let segments = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }

        for segment in segments {
            // English: words >= 3 chars, camelCase tokens
            if segment.unicodeScalars.allSatisfy({ $0.isASCII }) {
                let letters = segment.filter { $0.isLetter }
                if letters.count >= 3 {
                    addUnique(segment)
                }
                // Split camelCase and add full token
                let camelParts = splitCamelCase(segment)
                if camelParts.count > 1 {
                    addUnique(segment)
                }
            } else {
                // Chinese: extract continuous CJK segments of 2-8 characters
                var cjkRun = ""
                for char in segment {
                    if char.unicodeScalars.allSatisfy({ isCJK($0) }) {
                        cjkRun.append(char)
                    } else {
                        if cjkRun.count >= 2 && cjkRun.count <= 8 {
                            addUnique(cjkRun)
                        }
                        cjkRun = ""
                    }
                }
                if cjkRun.count >= 2 && cjkRun.count <= 8 {
                    addUnique(cjkRun)
                }
            }

            if keywords.count >= maxCount { break }
        }

        return Array(keywords.prefix(maxCount))
    }

    private static func splitCamelCase(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        for char in text {
            if char.isUppercase && !current.isEmpty {
                parts.append(current)
                current = String(char)
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        if v >= 0x4E00 && v <= 0x9FFF { return true }
        if v >= 0x3400 && v <= 0x4DBF { return true }
        if v >= 0x20000 && v <= 0x2A6DF { return true }
        return false
    }
}
