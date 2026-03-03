import Foundation

/// L2 Polish layer: routes text through a language model for spoken-to-written conversion.
///
/// Supports multiple backends (local llama.cpp, Ollama, OpenAI-compatible, FM adapter API).
/// Configuration-driven via WEConfig.polish settings.
/// Falls back to raw text pass-through if all backends are unavailable.
final class PolishClient: @unchecked Sendable {

    /// Backend types for polish routing.
    enum BackendType: String {
        case local    // On-device llama.cpp
        case ollama   // Ollama HTTP API
        case openai   // OpenAI-compatible API
        case fmAdapter = "fm-adapter-api" // FM adapter endpoint
    }

    /// A request to polish transcribed text.
    struct PolishRequest {
        let text: String
        let wordConfidences: [Float]
        let appBundleID: String
    }

    /// Result of a polish operation.
    struct PolishResult {
        let text: String
        let backend: BackendType?
        let latencyMs: Int
    }

    private let config: WEConfig.PolishConfig
    private let adapters: [String: String]
    private let localClient: LocalModelClient

    /// Initialize with configuration.
    ///
    /// - Parameters:
    ///   - config: The polish configuration from WEConfig.
    ///   - adapters: BundleID-to-adapter mapping from WEConfig.
    ///   - localClient: The shared LocalModelClient instance for on-device inference.
    init(config: WEConfig.PolishConfig, adapters: [String: String], localClient: LocalModelClient) {
        self.config = config
        self.adapters = adapters
        self.localClient = localClient
    }

    /// Convenience initializer from full WEConfig.
    convenience init(weConfig: WEConfig, localClient: LocalModelClient) {
        self.init(config: weConfig.polish, adapters: weConfig.adapters, localClient: localClient)
    }

    // MARK: - Public API

    /// Polish transcribed text using the configured backend.
    ///
    /// Routes to the appropriate backend based on config.type. If the primary
    /// backend fails, falls back to raw text pass-through (no modification).
    ///
    /// - Parameter request: The polish request containing text and metadata.
    /// - Returns: The polished text result.
    func polish(_ request: PolishRequest) async -> PolishResult {
        guard config.enabled else {
            return PolishResult(text: request.text, backend: nil, latencyMs: 0)
        }

        let start = DispatchTime.now()

        let backendType: BackendType
        switch config.type {
        case .local: backendType = .local
        case .ollama: backendType = .ollama
        case .openai: backendType = .openai
        case .fmAdapterApi: backendType = .fmAdapter
        }

        do {
            let polished: String
            switch backendType {
            case .local:
                polished = try await polishLocal(request)
            case .ollama:
                polished = try await polishHTTP(request, style: .ollama)
            case .openai:
                polished = try await polishHTTP(request, style: .openai)
            case .fmAdapter:
                polished = try await polishHTTP(request, style: .fmAdapter)
            }

            let elapsed = elapsedMs(since: start)
            DebugLog.log(.pipeline, "Polished via \(backendType.rawValue) in \(elapsed)ms")
            return PolishResult(text: polished, backend: backendType, latencyMs: elapsed)
        } catch {
            let elapsed = elapsedMs(since: start)
            DebugLog.log(.pipeline, "Backend \(backendType.rawValue) failed (\(error)), passing through", level: .warning)
            return PolishResult(text: request.text, backend: nil, latencyMs: elapsed)
        }
    }

    // MARK: - Local Backend

    private func polishLocal(_ request: PolishRequest) async throws -> String {
        // Hot-switch adapter if needed for target app.
        localClient.switchAdapterIfNeeded(
            for: request.appBundleID,
            config: WEConfig(polish: config, adapters: adapters, downloads: WEConfig.default.downloads)
        )

        guard localClient.isLoaded else {
            throw LocalModelClient.ModelError.modelNotLoaded
        }

        let prompt = buildPrompt(request.text)

        return try localClient.generate(
            prompt: prompt,
            maxTokens: config.maxTokens,
            temperature: Float(config.temperature),
            timeout: config.timeout
        )
    }

    // MARK: - HTTP Backends

    private enum HTTPStyle {
        case ollama
        case openai
        case fmAdapter
    }

    private func polishHTTP(_ request: PolishRequest, style: HTTPStyle) async throws -> String {
        guard let endpoint = config.endpoint, let url = URL(string: endpoint) else {
            throw PolishError.noEndpoint
        }

        let body: Data
        switch style {
        case .ollama:
            body = try buildOllamaRequest(request)
        case .openai:
            body = try buildOpenAIRequest(request)
        case .fmAdapter:
            body = try buildFMAdapterRequest(request)
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = body
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = config.timeout

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw PolishError.httpError(code)
        }

        return try extractResponse(from: data, style: style)
    }

    // MARK: - Request Building

    private func buildPrompt(_ text: String) -> String {
        return "<|im_start|>system\n\(config.systemPrompt)<|im_end|>\n<|im_start|>user\n\(text)<|im_end|>\n<|im_start|>assistant\n"
    }

    private func buildOllamaRequest(_ request: PolishRequest) throws -> Data {
        let payload: [String: Any] = [
            "model": "qwen3:0.6b",
            "prompt": buildPrompt(request.text),
            "stream": false,
            "options": [
                "temperature": config.temperature,
                "num_predict": config.maxTokens
            ]
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }

    private func buildOpenAIRequest(_ request: PolishRequest) throws -> Data {
        let payload: [String: Any] = [
            "messages": [
                ["role": "system", "content": config.systemPrompt],
                ["role": "user", "content": request.text]
            ],
            "temperature": config.temperature,
            "max_tokens": config.maxTokens
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }

    private func buildFMAdapterRequest(_ request: PolishRequest) throws -> Data {
        let payload: [String: Any] = [
            "text": request.text,
            "system_prompt": config.systemPrompt,
            "temperature": config.temperature,
            "max_tokens": config.maxTokens,
            "word_confidences": request.wordConfidences,
            "app_bundle_id": request.appBundleID
        ]
        return try JSONSerialization.data(withJSONObject: payload)
    }

    // MARK: - Response Extraction

    private func extractResponse(from data: Data, style: HTTPStyle) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PolishError.invalidResponse
        }

        switch style {
        case .ollama:
            // Ollama: {"response": "..."}
            if let text = json["response"] as? String {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        case .openai:
            // OpenAI: {"choices": [{"message": {"content": "..."}}]}
            if let choices = json["choices"] as? [[String: Any]],
               let first = choices.first,
               let message = first["message"] as? [String: Any],
               let content = message["content"] as? String {
                return content.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        case .fmAdapter:
            // FM adapter: {"text": "..."}
            if let text = json["text"] as? String {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        throw PolishError.invalidResponse
    }

    // MARK: - Helpers

    private func elapsedMs(since start: DispatchTime) -> Int {
        let end = DispatchTime.now()
        let nanos = end.uptimeNanoseconds - start.uptimeNanoseconds
        return Int(nanos / 1_000_000)
    }

    enum PolishError: Error, CustomStringConvertible {
        case noEndpoint
        case httpError(Int)
        case invalidResponse

        var description: String {
            switch self {
            case .noEndpoint: return "No endpoint configured"
            case .httpError(let code): return "HTTP error \(code)"
            case .invalidResponse: return "Invalid response format"
            }
        }
    }
}
