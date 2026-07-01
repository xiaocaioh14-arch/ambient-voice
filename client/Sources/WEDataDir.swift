import Foundation

/// ~/.we/ 数据目录管理（唯一权威入口）
///
/// 所有代码访问 ~/.we/ 都应通过本 enum，不要再写 `WEDataDir.url.appendingPathComponent("foo")` 字面字符串。
///
/// 目录树（含 Phase B 规划的归档子目录）：
///
///   ~/.we/
///     ├─ config.json                     运行时配置
///     ├─ debug.log                       全局日志
///     ├─ correction-dictionary.json      错词字典（蒸馏管线用）
///     ├─ dictionary.json                 用户私有术语数组（SA contextualStrings 用）
///     ├─ voice-history.jsonl             即时录音历史
///     ├─ meeting-history.jsonl           会议每段 L2 流式记录
///     ├─ corrections.jsonl               用户手动纠错（如开启）
///     ├─ audio/                          录音 wav
///     ├─ meetings/                       会议导出 markdown
///     ├─ models/                         本地模型（占位）
///     ├─ archive/                        归档：历史训练快照 / 字典审核中间产物 / 报告
///     │   ├─ dictionaries/
///     │   ├─ training-snapshots/
///     │   ├─ test-sets/
///     │   └─ reports/
///     └─ kpi/                            KPI 月度结果归档
///
/// 行为：`ensureExists()` 会创建上述全部子目录（如果不存在），文件按需被各组件首次写入时创建。
enum WEDataDir {
    /// 根目录 URL。
    static let url: URL = {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".we")
    }()

    // MARK: - 子目录 helpers（活跃目录）

    static var audio: URL    { url.appendingPathComponent("audio") }
    static var meetings: URL { url.appendingPathComponent("meetings") }
    static var models: URL   { url.appendingPathComponent("models") }
    static var kpi: URL      { url.appendingPathComponent("kpi") }

    // MARK: - 子目录 helpers（归档 / 评估产物，Phase B 规划）

    static var archive: URL                  { url.appendingPathComponent("archive") }
    static var archiveDictionaries: URL      { archive.appendingPathComponent("dictionaries") }
    static var archiveTrainingSnapshots: URL { archive.appendingPathComponent("training-snapshots") }
    static var archiveTestSets: URL          { archive.appendingPathComponent("test-sets") }
    static var archiveReports: URL           { archive.appendingPathComponent("reports") }

    // MARK: - 活跃文件名常量（避免散落字符串）

    enum FileName {
        static let config            = "config.json"
        static let log               = "debug.log"
        static let voiceHistory      = "voice-history.jsonl"
        static let meetingHistory    = "meeting-history.jsonl"
        static let corrections       = "corrections.jsonl"
        static let correctionDict    = "correction-dictionary.json"
        static let contextualDict    = "dictionary.json"            // README 文档化的 SA contextualStrings 用
    }

    // MARK: - 完整文件 URL 快捷

    static var configURL: URL         { url.appendingPathComponent(FileName.config) }
    static var logURL: URL            { url.appendingPathComponent(FileName.log) }
    static var voiceHistoryURL: URL   { url.appendingPathComponent(FileName.voiceHistory) }
    static var meetingHistoryURL: URL { url.appendingPathComponent(FileName.meetingHistory) }
    static var correctionsURL: URL    { url.appendingPathComponent(FileName.corrections) }
    static var correctionDictURL: URL { url.appendingPathComponent(FileName.correctionDict) }
    static var contextualDictURL: URL { url.appendingPathComponent(FileName.contextualDict) }

    // MARK: - 派生路径（按时间戳产生）

    /// 生成一个 audio/*.wav 路径（不创建文件）
    static func audioURL(forName name: String, ext: String = "wav") -> URL {
        audio.appendingPathComponent("\(name).\(ext)")
    }

    /// 生成 audio/remote-*.wav 路径
    static func remoteAudioURL(timestamp: String) -> URL {
        audio.appendingPathComponent("remote-\(timestamp).wav")
    }

    /// 生成 meetings/*.md 路径
    static func meetingMarkdownURL(forName name: String) -> URL {
        meetings.appendingPathComponent("\(name).md")
    }

    // MARK: - 初始化

    /// 确保所有活跃 / 归档子目录存在
    static func ensureExists() {
        let fm = FileManager.default
        let dirs: [URL] = [
            url,
            audio,
            meetings,
            models,
            kpi,
            archive,
            archiveDictionaries,
            archiveTrainingSnapshots,
            archiveTestSets,
            archiveReports,
        ]
        for dir in dirs {
            if !fm.fileExists(atPath: dir.path) {
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
        }
        Logger.log("DataDir", "Ensured ~/.we/ structure exists")
    }
}
