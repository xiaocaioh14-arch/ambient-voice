import Foundation

struct WEConfig: Codable, Sendable {
    var polish: PolishConfig
    var adapters: [String: String]
    var downloads: DownloadConfig

    // MARK: - Polish

    struct PolishConfig: Codable, Sendable {
        var enabled: Bool
        var type: PolishType
        var systemPrompt: String
        var temperature: Double
        var maxTokens: Int
        var timeout: Double
        var endpoint: String?

        enum CodingKeys: String, CodingKey {
            case enabled, type
            case systemPrompt = "system_prompt"
            case temperature
            case maxTokens = "max_tokens"
            case timeout, endpoint
        }
    }

    enum PolishType: String, Codable, Sendable {
        case local
        case ollama
        case openai
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

    // MARK: - Defaults

    static let `default` = WEConfig(
        polish: PolishConfig(
            enabled: true,
            type: .local,
            systemPrompt: "口语转书面。只输出结果。",
            temperature: 0,
            maxTokens: 256,
            timeout: 10,
            endpoint: nil
        ),
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
