import Foundation

struct WEConfig: Codable, Sendable {
    var polish: PolishConfig?
    var adapters: [String: String]
    var keywords: [String]?
    var replacements: [String: String]?
    var downloads: DownloadConfig
    var screenContext: ScreenContextConfig?
    var meeting: MeetingConfig?
    var distillation: DistillationConfig?

    // MARK: - Polish

    struct PolishConfig: Codable, Sendable {
        var enabled: Bool
        var type: PolishType
        var systemPrompt: String
        var temperature: Double
        var maxTokens: Int
        var timeout: Double
        var endpoint: String?
        var apiKey: String?
        var model: String?

        enum CodingKeys: String, CodingKey {
            case enabled, type
            case systemPrompt = "system_prompt"
            case temperature
            case maxTokens = "max_tokens"
            case timeout, endpoint
            case apiKey = "api_key"
            case model
        }
    }

    enum PolishType: String, Codable, Sendable {
        case local
        case ollama
        case openai
        case anthropic
        case fmAdapterApi = "fm-adapter-api"
    }

    // MARK: - Downloads

    struct DownloadConfig: Codable, Sendable {
        var baseModel: String
        var adapter: String
        var manifest: String

        enum CodingKeys: String, CodingKey {
            case baseModel = "base_model"
            case adapter, manifest
        }
    }

    // MARK: - Screen Context

    struct ScreenContextConfig: Codable, Sendable {
        var enabled: Bool
        var maxKeywords: Int
        var ocrTimeout: Double

        enum CodingKeys: String, CodingKey {
            case enabled
            case maxKeywords = "max_keywords"
            case ocrTimeout = "ocr_timeout"
        }

        static let `default` = ScreenContextConfig(
            enabled: false,
            maxKeywords: 20,
            ocrTimeout: 2.0
        )
    }

    // MARK: - Meeting

    struct MeetingConfig: Codable, Sendable {
        var enabled: Bool
        var silenceThresholdMs: Int
        var chunkDurationSec: Int
        var panelOpacity: Double
        var saveAudio: Bool

        enum CodingKeys: String, CodingKey {
            case enabled
            case silenceThresholdMs = "silence_threshold_ms"
            case chunkDurationSec = "chunk_duration_sec"
            case panelOpacity = "panel_opacity"
            case saveAudio = "save_audio"
        }

        static let `default` = MeetingConfig(
            enabled: true,
            silenceThresholdMs: 1500,
            chunkDurationSec: 300,
            panelOpacity: 0.85,
            saveAudio: true
        )
    }

    // MARK: - Distillation

    struct DistillationConfig: Codable, Sendable {
        var saveAudio: Bool
        var whisperEndpoint: String?
        var geminiEndpoint: String?
        var geminiApiKey: String?
        var audioRetentionDays: Int

        enum CodingKeys: String, CodingKey {
            case saveAudio = "save_audio"
            case whisperEndpoint = "whisper_endpoint"
            case geminiEndpoint = "gemini_endpoint"
            case geminiApiKey = "gemini_api_key"
            case audioRetentionDays = "audio_retention_days"
        }

        static let `default` = DistillationConfig(
            saveAudio: false,
            whisperEndpoint: nil,
            geminiEndpoint: nil,
            geminiApiKey: nil,
            audioRetentionDays: 30
        )
    }

    // MARK: - Audio Constants

    /// Shared audio format constants for meeting mode and distillation.
    enum AudioConstants {
        static let sampleRate: Double = 16000
        static let channels: UInt32 = 1
        static let bitsPerChannel: UInt32 = 16
    }

    // MARK: - Defaults

    static let `default` = WEConfig(
        polish: nil,
        adapters: [
            "com.apple.Terminal": "coding.gguf",
            "com.tencent.xinWeChat": "chat.gguf"
        ],
        downloads: DownloadConfig(
            baseModel: "http://4090.ts.andy.qzz.io:9191/qwen3-0.6b.gguf",
            adapter: "http://4090.ts.andy.qzz.io:9191/sa-adapter.gguf",
            manifest: "http://4090.ts.andy.qzz.io:9191/manifest.json"
        )
    )

    // MARK: - File I/O

    private static let configDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".we")
    }()

    static var configFileURL: URL {
        configDir.appendingPathComponent("config.json")
    }

    /// Load config from ~/.we/config.json, creating the default if missing.
    static func load() -> WEConfig {
        let url = configFileURL
        let fm = FileManager.default

        if !fm.fileExists(atPath: url.path) {
            let config = WEConfig.default
            try? fm.createDirectory(at: configDir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(config) {
                try? data.write(to: url)
            }
            return config
        }

        guard let data = try? Data(contentsOf: url) else {
            return .default
        }
        let decoder = JSONDecoder()
        return (try? decoder.decode(WEConfig.self, from: data)) ?? .default
    }

    /// Return the adapter GGUF filename for a given bundle identifier, if any.
    func adapterPath(for bundleID: String) -> String? {
        adapters[bundleID]
    }
}
