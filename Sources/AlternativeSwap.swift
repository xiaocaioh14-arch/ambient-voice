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
    static let minimumHistoryCount = 1

    /// Result of L1 correction, including per-word outputs for L2 alignment.
    struct L1Result {
        let text: String
        /// Per-word L1 output aligned with the input words array.
        /// For multi-word replacements, the first consumed word gets the replacement
        /// and subsequent consumed words get empty strings.
        let wordTexts: [String]
    }

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
    /// - Returns: L1Result with corrected text and per-word outputs.
    static func apply(
        rawText: String,
        words: [TranscribedWord],
        correctionHistory: [CorrectionEntry],
        contextKeywords: [String] = [],
        replacements: [String: String] = [:]
    ) -> L1Result {
        guard !words.isEmpty else {
            DebugLog.log(.pipeline, "L1 skipped: no words", level: .debug)
            return L1Result(text: rawText, wordTexts: [])
        }

        let correctionMap = buildCorrectionMap(from: correctionHistory)
        let keywordSet = Set(contextKeywords.map { $0.lowercased() })

        // Build case-insensitive replacement map from config.
        let forceMap = Dictionary(uniqueKeysWithValues:
            replacements.map { ($0.key.lowercased(), $0.value) }
        )

        // If no correction sources at all, return original text unchanged.
        guard !correctionMap.isEmpty || !keywordSet.isEmpty || !forceMap.isEmpty else {
            DebugLog.log(.pipeline, "L1 pass-through: no correction sources", level: .debug)
            return L1Result(text: rawText, wordTexts: words.map(\.text))
        }

        // Pre-compute multi-char force replacement keys grouped by length (descending).
        let maxForceLen = forceMap.keys.map(\.count).max() ?? 0

        // Per-word L1 outputs, aligned with input words array.
        var wordTexts = [String](repeating: "", count: words.count)
        var i = 0

        while i < words.count {
            // Try multi-word sliding window for force replacements (longest match first).
            var matched = false
            if maxForceLen > 0 {
                let maxWindow = min(maxForceLen, words.count - i)
                for windowLen in stride(from: maxWindow, through: 1, by: -1) {
                    let combined = words[i..<(i + windowLen)].map(\.text).joined().lowercased()
                    if let forced = forceMap[combined] {
                        wordTexts[i] = forced
                        DebugLog.log(.pipeline, "L1 force: \"\(combined)\" → \"\(forced)\"")
                        for j in (i + 1)..<(i + windowLen) {
                            wordTexts[j] = ""
                        }
                        i += windowLen
                        matched = true
                        break
                    }
                }
            }
            if matched { continue }

            let word = words[i]
            // Single-word: try exact match first, then substring match for force replacements.
            if let forced = forceMap[word.text.lowercased()] {
                wordTexts[i] = forced
                DebugLog.log(.pipeline, "L1 force: \"\(word.text)\" → \"\(forced)\"")
            } else if let (from, to) = substringForceMatch(word.text, forceMap: forceMap) {
                // SA merged the key with surrounding chars (e.g. "户口的" contains "户口")
                let replaced = word.text.lowercased().replacingOccurrences(of: from, with: to)
                // Restore original casing for non-replaced parts
                wordTexts[i] = restoreCase(original: word.text, lowercased: replaced, replacedFrom: from, replacedTo: to)
                DebugLog.log(.pipeline, "L1 force-substr: \"\(word.text)\" → \"\(wordTexts[i])\" (matched \"\(from)\"→\"\(to)\")")
            } else if let replacement = findBestAlternative(for: word, correctionMap: correctionMap, contextKeywords: keywordSet) {
                wordTexts[i] = replacement
            } else {
                wordTexts[i] = word.text
            }
            i += 1
        }

        // Rebuild text preserving original spacing from rawText.
        let finalText = rebuildWithSpacing(rawText: rawText, words: words, wordTexts: wordTexts)
        return L1Result(text: finalText, wordTexts: wordTexts)
    }

    // MARK: - Force Replacement Helpers

    /// Substring match: check if any forceMap key is a substring of the word.
    /// Returns the matched (key, value) pair, or nil.
    private static func substringForceMatch(
        _ wordText: String,
        forceMap: [String: String]
    ) -> (String, String)? {
        let lower = wordText.lowercased()
        // Prefer longer keys first to avoid partial matches.
        for (key, value) in forceMap.sorted(by: { $0.key.count > $1.key.count }) {
            if lower.contains(key) && lower != key {
                return (key, value)
            }
        }
        return nil
    }

    /// Restore original casing for the non-replaced parts of the word.
    private static func restoreCase(
        original: String,
        lowercased: String,
        replacedFrom: String,
        replacedTo: String
    ) -> String {
        // Find where the replacement happened in the lowercased string.
        guard let range = original.lowercased().range(of: replacedFrom) else {
            return lowercased
        }
        let before = String(original[original.startIndex..<range.lowerBound])
        let after = String(original[range.upperBound...])
        return before + replacedTo + after
    }

    /// Rebuild final text preserving the spacing pattern from rawText.
    /// Scans rawText to detect spaces between word boundaries, then inserts
    /// the same spaces between the corrected wordTexts.
    private static func rebuildWithSpacing(
        rawText: String,
        words: [TranscribedWord],
        wordTexts: [String]
    ) -> String {
        guard words.count > 1 else { return wordTexts.joined() }

        // Build a map of which word boundaries had spaces in the original rawText.
        // Strategy: walk rawText character by character, matching word texts sequentially.
        var hasSpaceAfter = [Bool](repeating: false, count: words.count)
        var searchPos = rawText.startIndex
        for (idx, word) in words.enumerated() {
            guard let foundRange = rawText.range(of: word.text, range: searchPos..<rawText.endIndex) else {
                continue
            }
            // Check if there's whitespace between end of this word and start of next word's text.
            let afterWord = foundRange.upperBound
            if afterWord < rawText.endIndex && rawText[afterWord].isWhitespace {
                hasSpaceAfter[idx] = true
            }
            searchPos = foundRange.upperBound
        }

        var result = ""
        for (idx, wordText) in wordTexts.enumerated() {
            result += wordText
            if idx < words.count - 1 && hasSpaceAfter[idx] {
                result += " "
            }
        }
        return result
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
            let finalWords = tokenize(entry.userFinalText)

            // Learn from SA raw text → user final (corrects speech recognition errors).
            let rawWords = tokenize(entry.rawText)
            let rawDiffs = wordLevelDiff(original: rawWords, corrected: finalWords)
            for (original, corrected) in rawDiffs {
                pairCounts[original.lowercased(), default: [:]][corrected, default: 0] += 1
            }

            // Also learn from inserted text → user final (corrects L1/L2 pipeline errors).
            if entry.insertedText != entry.rawText {
                let insertedWords = tokenize(entry.insertedText)
                let pipelineDiffs = wordLevelDiff(original: insertedWords, corrected: finalWords)
                for (original, corrected) in pipelineDiffs {
                    pairCounts[original.lowercased(), default: [:]][corrected, default: 0] += 1
                }
            }
        }

        // Only include mappings that appear frequently enough.
        // Single CJK characters need higher threshold to avoid over-fitting
        // (e.g. "你"→"功能" from one truncated correction would corrupt all inputs).
        var map: [String: String] = [:]
        for (original, corrections) in pairCounts {
            if let (bestCorrection, count) = corrections.max(by: { $0.value < $1.value }) {
                let isSingleCJK = original.count == 1 && original.unicodeScalars.allSatisfy({ isCJK($0) })
                let threshold = isSingleCJK ? 3 : minimumHistoryCount
                guard count >= threshold else { continue }
                map[original] = bestCorrection
                DebugLog.log(.correction, "Correction map: \"\(original)\" → \"\(bestCorrection)\" (count: \(count))")
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
        correctionMap: [String: String],
        contextKeywords: Set<String> = []
    ) -> String? {
        let key = word.text.lowercased()

        // History-based correction: user has corrected this word before.
        // Always apply regardless of confidence — user corrections are authoritative.
        if let corrected = correctionMap[key] {
            DebugLog.log(.pipeline, "L1 history: \"\(word.text)\" → \"\(corrected)\" (conf=\(String(format: "%.2f", word.confidence)))")
            return corrected
        }

        // Check alternatives against correction map (also ignores confidence).
        for alt in word.alternatives {
            let altKey = alt.lowercased()
            if let corrected = correctionMap[altKey] {
                DebugLog.log(.pipeline, "L1 history-alt: \"\(word.text)\"→\"\(alt)\" → \"\(corrected)\"")
                return corrected
            }
        }

        // Context keywords and alternatives: only for low-confidence words.
        guard word.confidence < confidenceThreshold else { return nil }

        if !contextKeywords.isEmpty {
            for alt in word.alternatives {
                if contextKeywords.contains(alt.lowercased()) {
                    DebugLog.log(.pipeline, "L1 context: \"\(word.text)\" → \"\(alt)\" (screen keyword)")
                    return alt
                }
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
            var origChanged: [String] = []
            var corrChanged: [String] = []

            if li < lcs.count {
                while oi < original.count && original[oi] != lcs[li] {
                    origChanged.append(original[oi])
                    oi += 1
                }
                while ci < corrected.count && corrected[ci] != lcs[li] {
                    corrChanged.append(corrected[ci])
                    ci += 1
                }
                // Skip the matching LCS element.
                oi += 1
                ci += 1
                li += 1
            } else {
                while oi < original.count { origChanged.append(original[oi]); oi += 1 }
                while ci < corrected.count { corrChanged.append(corrected[ci]); ci += 1 }
            }

            guard !origChanged.isEmpty || !corrChanged.isEmpty else { continue }

            if origChanged.count == corrChanged.count {
                // Equal length: pair 1:1.
                for i in 0..<origChanged.count {
                    if origChanged[i].lowercased() != corrChanged[i].lowercased() {
                        diffs.append((origChanged[i], corrChanged[i]))
                    }
                }
            } else if !origChanged.isEmpty && !corrChanged.isEmpty {
                // Unequal length: record as a joined segment pair.
                let origJoined = origChanged.joined()
                let corrJoined = corrChanged.joined()
                if origJoined.lowercased() != corrJoined.lowercased() {
                    diffs.append((origJoined, corrJoined))
                }
            }

            if li >= lcs.count && oi >= original.count && ci >= corrected.count { break }
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
