import Foundation

/// L1 Deterministic Correction Layer
///
/// Uses Speech API alternatives and user correction history to perform
/// rule-based text replacement. No model inference — pure deterministic logic.
///
/// Key principle: 不确定时不改 (when uncertain, don't change — better than wrong changes)
struct AlternativeSwap {

    /// Confidence threshold below which alternatives are considered for swapping.
    static let confidenceThreshold: Float = 0.5

    /// Minimum number of times a correction must appear in history before it is trusted.
    static let minimumHistoryCount = 2

    // MARK: - Public API

    /// Apply deterministic corrections based on SA alternatives and correction history.
    ///
    /// For each low-confidence word, checks whether any alternative matches a known
    /// correction target from user history. High-confidence words are never modified.
    ///
    /// - Parameters:
    ///   - rawText: The full raw transcription text.
    ///   - words: Word-level transcription results with confidence and alternatives.
    ///   - correctionHistory: Past correction entries from CorrectionStore.
    /// - Returns: The corrected text string.
    static func apply(
        rawText: String,
        words: [TranscribedWord],
        correctionHistory: [CorrectionEntry]
    ) -> String {
        guard !words.isEmpty else { return rawText }

        let correctionMap = buildCorrectionMap(from: correctionHistory)

        // If no correction history, return original text unchanged.
        guard !correctionMap.isEmpty else { return rawText }

        var resultParts: [String] = []

        for word in words {
            if let replacement = findBestAlternative(for: word, correctionMap: correctionMap) {
                resultParts.append(replacement)
            } else {
                resultParts.append(word.text)
            }
        }

        return resultParts.joined()
    }

    // MARK: - Private Helpers

    /// Build a word-level correction map from correction history.
    ///
    /// Analyzes user correction entries to find repeated word-level substitutions.
    /// Only includes mappings that appear at least `minimumHistoryCount` times.
    ///
    /// - Parameter history: Array of past correction entries.
    /// - Returns: Dictionary mapping original words to their corrected forms.
    private static func buildCorrectionMap(from history: [CorrectionEntry]) -> [String: String] {
        // Count occurrences of each (original -> corrected) word pair.
        var pairCounts: [String: [String: Int]] = [:]

        for entry in history {
            let rawWords = tokenize(entry.rawText)
            let finalWords = tokenize(entry.userFinalText)

            // Simple LCS-based diff to find word-level changes.
            let diffs = wordLevelDiff(original: rawWords, corrected: finalWords)
            for (original, corrected) in diffs {
                let key = original.lowercased()
                let val = corrected
                pairCounts[key, default: [:]][val, default: 0] += 1
            }
        }

        // Only include mappings that appear frequently enough.
        var map: [String: String] = [:]
        for (original, corrections) in pairCounts {
            if let (bestCorrection, count) = corrections.max(by: { $0.value < $1.value }),
               count >= minimumHistoryCount {
                map[original] = bestCorrection
            }
        }

        return map
    }

    /// Check if an alternative is a better match based on correction history.
    ///
    /// Only considers words below the confidence threshold. Returns the best
    /// alternative if one matches a known correction, otherwise nil.
    ///
    /// - Parameters:
    ///   - word: The transcribed word to evaluate.
    ///   - correctionMap: Known corrections from user history.
    /// - Returns: The replacement string, or nil if no swap should be made.
    private static func findBestAlternative(
        for word: TranscribedWord,
        correctionMap: [String: String]
    ) -> String? {
        // Never touch high-confidence words.
        guard word.confidence < confidenceThreshold else { return nil }

        let key = word.text.lowercased()

        // Check if the primary word itself has a known correction.
        if let corrected = correctionMap[key] {
            return corrected
        }

        // Check if any alternative matches a known correction target.
        for alt in word.alternatives {
            let altKey = alt.lowercased()
            if let corrected = correctionMap[altKey] {
                return corrected
            }
        }

        return nil
    }

    // MARK: - Text Processing Utilities

    /// Simple tokenizer that splits text on whitespace and punctuation boundaries,
    /// preserving the original tokens for Chinese/CJK character-level splitting.
    private static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""

        for char in text {
            if char.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else if char.unicodeScalars.allSatisfy({ isCJK($0) }) {
                // Each CJK character is its own token.
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                tokens.append(String(char))
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty {
            tokens.append(current)
        }

        return tokens
    }

    /// Check if a Unicode scalar is a CJK character.
    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        // CJK Unified Ideographs
        if v >= 0x4E00 && v <= 0x9FFF { return true }
        // CJK Unified Ideographs Extension A
        if v >= 0x3400 && v <= 0x4DBF { return true }
        // CJK Unified Ideographs Extension B
        if v >= 0x20000 && v <= 0x2A6DF { return true }
        // CJK Compatibility Ideographs
        if v >= 0xF900 && v <= 0xFAFF { return true }
        return false
    }

    /// Compute word-level diff between original and corrected token arrays.
    /// Returns pairs of (original, corrected) for changed words.
    private static func wordLevelDiff(
        original: [String],
        corrected: [String]
    ) -> [(String, String)] {
        // Use LCS (Longest Common Subsequence) to identify unchanged words,
        // then pair up the changed segments.
        let lcs = longestCommonSubsequence(original, corrected)
        var diffs: [(String, String)] = []

        var oi = 0, ci = 0, li = 0

        while oi < original.count || ci < corrected.count {
            if li < lcs.count {
                // Collect words before the next LCS match.
                var origChanged: [String] = []
                var corrChanged: [String] = []

                while oi < original.count && original[oi] != lcs[li] {
                    origChanged.append(original[oi])
                    oi += 1
                }
                while ci < corrected.count && corrected[ci] != lcs[li] {
                    corrChanged.append(corrected[ci])
                    ci += 1
                }

                // Pair up changes 1:1 where possible.
                let pairCount = min(origChanged.count, corrChanged.count)
                for i in 0..<pairCount {
                    if origChanged[i].lowercased() != corrChanged[i].lowercased() {
                        diffs.append((origChanged[i], corrChanged[i]))
                    }
                }

                // Skip the matching LCS element.
                oi += 1
                ci += 1
                li += 1
            } else {
                // After LCS is exhausted, remaining words are changes.
                var origChanged: [String] = []
                var corrChanged: [String] = []

                while oi < original.count {
                    origChanged.append(original[oi])
                    oi += 1
                }
                while ci < corrected.count {
                    corrChanged.append(corrected[ci])
                    ci += 1
                }

                let pairCount = min(origChanged.count, corrChanged.count)
                for i in 0..<pairCount {
                    if origChanged[i].lowercased() != corrChanged[i].lowercased() {
                        diffs.append((origChanged[i], corrChanged[i]))
                    }
                }
                break
            }
        }

        return diffs
    }

    /// Standard LCS algorithm for string arrays.
    private static func longestCommonSubsequence(_ a: [String], _ b: [String]) -> [String] {
        let m = a.count
        let n = b.count
        guard m > 0 && n > 0 else { return [] }

        // Build DP table.
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 1...m {
            for j in 1...n {
                if a[i - 1] == b[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                } else {
                    dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }

        // Backtrack to find the actual subsequence.
        var result: [String] = []
        var i = m, j = n
        while i > 0 && j > 0 {
            if a[i - 1] == b[j - 1] {
                result.append(a[i - 1])
                i -= 1
                j -= 1
            } else if dp[i - 1][j] > dp[i][j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }

        return result.reversed()
    }
}
