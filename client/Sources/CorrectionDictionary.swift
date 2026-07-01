import Foundation

/// 加载词典并抽取「正确词」列表，注入 SA 的 contextualStrings 作为 hint。
///
/// 兼容两种词典格式（按 value 类型自动判别，取「正确词」那一侧）:
/// - correction-dictionary.json: `{"正确词": {"errors":[...], "frequency":N}}` → 取 **key**（正确词）
/// - dictionary.json:            `{"错词": "正确词"}`                          → 取 **value**（正确词）
/// 抽错方向会把「错词」喂给 ASR、教它往错里听，所以这里必须取正确词那一侧。
@MainActor
final class CorrectionDictionary {
    static let shared = CorrectionDictionary()

    private(set) var terms: [String] = []
    private(set) var loadedPath: String?

    private init() {}

    /// 加载字典，返回是否成功
    @discardableResult
    func load(from path: String) -> Bool {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        guard FileManager.default.fileExists(atPath: expanded),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Logger.log("Dict", "Load failed: \(expanded)")
            terms = []
            loadedPath = nil
            return false
        }

        // 按 value 类型判别格式，统一抽出「正确词」那一侧。
        var correctTerms: [String] = []
        var seen = Set<String>()
        for (key, value) in json {
            let term: String
            if let correct = value as? String {
                // dictionary.json: {"错词": "正确词"} → value 是正确词
                term = correct
            } else {
                // correction-dictionary.json: {"正确词": {...}} → key 是正确词
                term = key
            }
            guard !term.isEmpty, seen.insert(term).inserted else { continue }
            correctTerms.append(term)
        }
        terms = correctTerms
        loadedPath = expanded
        Logger.log("Dict", "Loaded \(correctTerms.count) terms from \(expanded)")
        return true
    }
}
