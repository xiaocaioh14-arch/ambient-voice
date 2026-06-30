import Foundation

/// 纯文本词典纠错器 (会议模式专用)
///
/// 与 L1 的 AlternativeSwap 不同:AlternativeSwap 需要 word-level 的 confidence/alternatives
/// (语音输入管线有),会议转写只给纯文本字符串,拿不到这些。所以这里做的是
/// **整段文本上的确定性强制替换**——词典里的词本来就该无条件替换,不依赖置信度。
///
/// 共享同一份 ~/.we/dictionary.json,带热更新 (改词典不用重启)。
///
/// 匹配规则 (防误伤):
/// - **单遍扫描,已替换区不回头**: 输出过的内容绝不被后续规则二次匹配,
///   从根上杜绝链式替换 (规则 A 的 value 恰好是规则 B 的 key 时不会连环触发)。
/// - **同一位置长 key 优先**: "Serian Juno" 先于 "Serin" 匹配,避免半截替换。
/// - **CJK key 直接子串匹配**: 中文没有词边界,"海南"→"海缆" 直接换。
/// - **拉丁 key 要求词边界**: "cold"→"Code" 只在独立单词时换,不会把 "coldplay" 改成 "Codeplay"。
///   边界 = 两侧是非字母数字 (空格/标点/CJK/串首尾)。大小写不敏感。
@MainActor
final class DictionaryCorrector {

    static let shared = DictionaryCorrector()

    private struct Rule {
        let key: [Character]      // 原始 key 的字符数组
        let lowerKey: [Character] // 小写化的 key (拉丁匹配用)
        let value: String
        let isLatin: Bool
    }

    /// 词典条目,按 key 长度降序排列 (同一位置长 key 优先匹配)。
    private var rules: [Rule] = []
    private var watcher: DictionaryWatcher?

    private init() {
        reload(with: WEConfig.loadDictionary())
        // 热更新:dictionary.json 变更时重建规则。
        watcher = WEConfig.startDictionaryWatcher { [weak self] merged in
            Task { @MainActor in self?.reload(with: merged) }
        }
    }

    /// 用新词典重建匹配规则。
    private func reload(with dict: [String: String]) {
        rules = dict
            .compactMap { (k, v) -> Rule? in
                guard !k.isEmpty else { return nil }
                return Rule(
                    key: Array(k),
                    lowerKey: Array(k.lowercased()),
                    value: v,
                    isLatin: Self.isLatinKey(k)
                )
            }
            .sorted { $0.key.count > $1.key.count }
        Logger.log("DictionaryCorrector", "Loaded \(rules.count) rules")
    }

    /// 对整段文本应用词典纠错,返回纠正后的文本。
    ///
    /// **单遍左到右扫描**:在每个位置,按长度降序试所有规则,命中即写入 value 并把
    /// 游标跳过被消费的源字符——已输出的内容 (无论是原文还是 value) 都不会再被任何规则
    /// 重新检查,因此不存在二次/链式替换。
    func correct(_ text: String) -> String {
        guard !text.isEmpty, !rules.isEmpty else { return text }
        let chars = Array(text)
        var out = ""
        out.reserveCapacity(chars.count)
        var i = 0
        while i < chars.count {
            var matched = false
            for rule in rules {
                if let consumed = Self.matchAt(i, in: chars, rule: rule) {
                    out += rule.value
                    i += consumed
                    matched = true
                    break
                }
            }
            if !matched {
                out.append(chars[i])
                i += 1
            }
        }
        return out
    }

    // MARK: - Helpers

    /// 尝试在 chars[i] 处匹配 rule。命中返回消费的字符数,否则 nil。
    private static func matchAt(_ i: Int, in chars: [Character], rule: Rule) -> Int? {
        let n = rule.key.count
        guard i + n <= chars.count else { return nil }

        if rule.isLatin {
            // 大小写不敏感逐字符比对。
            for j in 0..<n where Character(chars[i + j].lowercased()) != rule.lowerKey[j] {
                return nil
            }
            // 词边界:两侧非字母数字 (或串首尾)。
            let before = i == 0 ? nil : chars[i - 1]
            let after = i + n >= chars.count ? nil : chars[i + n]
            guard isBoundary(before), isBoundary(after) else { return nil }
        } else {
            // CJK / 数字 key:大小写敏感精确比对,无边界要求。
            for j in 0..<n where chars[i + j] != rule.key[j] {
                return nil
            }
        }
        return n
    }

    /// key 是否为"拉丁型"——首字符是 ASCII 字母 (需要词边界保护)。
    /// CJK / 数字开头的 key 走直接子串匹配。
    private static func isLatinKey(_ key: String) -> Bool {
        guard let first = key.first else { return false }
        return first.isASCII && first.isLetter
    }

    /// 词边界判定:nil (串首尾) 或非字母数字 (空格/标点/CJK) 算边界。
    /// 这样 "cold" 在 "cold start" 里命中,在 "coldplay" 里不命中。
    private static func isBoundary(_ ch: Character?) -> Bool {
        guard let ch = ch else { return true }
        return !(ch.isLetter || ch.isNumber)
    }
}
