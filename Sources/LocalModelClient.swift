import Foundation
import CllmBase

/// Wraps the llama.cpp C API for on-device inference with GGUF models.
///
/// Manages model lifecycle (load, inference, unload) and supports hot-switching
/// LoRA adapters per app (bundleID -> adapter mapping from WEConfig).
/// All inference calls are thread-safe via a serial dispatch queue.
final class LocalModelClient: @unchecked Sendable {

    /// Errors specific to local model operations.
    enum ModelError: Error, CustomStringConvertible {
        case modelNotLoaded
        case loadFailed(String)
        case inferenceFailed(String)
        case timeout

        var description: String {
            switch self {
            case .modelNotLoaded: return "Model not loaded"
            case .loadFailed(let msg): return "Model load failed: \(msg)"
            case .inferenceFailed(let msg): return "Inference failed: \(msg)"
            case .timeout: return "Inference timed out"
            }
        }
    }

    /// Directory where models are stored (~/.we/models/).
    static let modelsDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".we")
            .appendingPathComponent("models")
    }()

    private let queue = DispatchQueue(label: "io.we.localmodel", qos: .userInitiated)

    private var model: OpaquePointer?       // llama_model*
    private var defaultCtx: OpaquePointer?  // llama_context*
    private var currentAdapter: OpaquePointer? // llama_adapter_lora*
    private var currentModelPath: String?
    private var currentAdapterPath: String?

    deinit {
        unload()
    }

    // MARK: - Model Lifecycle

    /// Load a base GGUF model from the models directory.
    ///
    /// - Parameter filename: The GGUF filename (e.g., "qwen3-0.6b.gguf").
    /// - Throws: `ModelError.loadFailed` if the model cannot be loaded.
    func loadModel(filename: String) throws {
        let path = Self.modelsDir.appendingPathComponent(filename).path

        guard FileManager.default.fileExists(atPath: path) else {
            throw ModelError.loadFailed("File not found: \(path)")
        }

        queue.sync {
            unloadInternal()

            var params = llama_model_default_params()
            params.n_gpu_layers = 99 // Offload all layers to GPU (Metal)

            self.model = llama_model_load_from_file(path, params)
            if self.model != nil {
                self.currentModelPath = path
                self.createContext()
            }
        }

        guard model != nil else {
            throw ModelError.loadFailed("llama_model_load_from_file returned nil for \(path)")
        }

        DebugLog.log(.model, "Loaded model: \(filename)")
    }

    /// Apply a LoRA adapter to the currently loaded model.
    ///
    /// - Parameter filename: The adapter GGUF filename (e.g., "sa-adapter.gguf").
    /// - Throws: `ModelError.loadFailed` if the adapter cannot be applied.
    func applyAdapter(filename: String) throws {
        guard let model = self.model else {
            throw ModelError.modelNotLoaded
        }

        let path = Self.modelsDir.appendingPathComponent(filename).path

        guard FileManager.default.fileExists(atPath: path) else {
            throw ModelError.loadFailed("Adapter not found: \(path)")
        }

        try queue.sync {
            // Remove existing context and adapter before changing.
            if let ctx = self.defaultCtx {
                llama_free(ctx)
                self.defaultCtx = nil
            }
            if let oldAdapter = self.currentAdapter {
                llama_adapter_lora_free(oldAdapter)
                self.currentAdapter = nil
            }

            guard let adapter = llama_adapter_lora_init(model, path) else {
                self.createContext()
                throw ModelError.loadFailed("Failed to load adapter: \(path)")
            }

            self.currentAdapter = adapter
            self.createContext()

            guard let ctx = self.defaultCtx else {
                throw ModelError.loadFailed("Failed to create context after adapter load")
            }

            var adapters: [OpaquePointer?] = [adapter]
            var scales: [Float] = [1.0]
            let result = llama_set_adapters_lora(ctx, &adapters, 1, &scales)
            guard result == 0 else {
                throw ModelError.loadFailed("Failed to apply adapter: \(path)")
            }

            self.currentAdapterPath = path
        }

        DebugLog.log(.model, "Applied adapter: \(filename)")
    }

    /// Hot-switch adapter based on the target application's bundle ID.
    ///
    /// Looks up the adapter mapping in WEConfig. If the bundle ID has a specific
    /// adapter and it differs from the current one, switches to it.
    ///
    /// - Parameters:
    ///   - bundleID: The target app's bundle identifier.
    ///   - config: The current WEConfig to look up adapter mappings.
    func switchAdapterIfNeeded(for bundleID: String, config: WEConfig) {
        guard let adapterFilename = config.adapterPath(for: bundleID) else { return }

        let adapterPath = Self.modelsDir.appendingPathComponent(adapterFilename).path
        guard adapterPath != currentAdapterPath else { return }

        do {
            try applyAdapter(filename: adapterFilename)
        } catch {
            DebugLog.log(.model, "Failed to switch adapter for \(bundleID): \(error)", level: .error)
        }
    }

    /// Unload all model resources.
    func unload() {
        queue.sync { unloadInternal() }
    }

    /// Whether a model is currently loaded and ready for inference.
    var isLoaded: Bool {
        queue.sync { model != nil && defaultCtx != nil }
    }

    // MARK: - Inference

    /// Run inference on the loaded model.
    ///
    /// - Parameters:
    ///   - prompt: The formatted prompt string.
    ///   - maxTokens: Maximum number of tokens to generate.
    ///   - temperature: Sampling temperature (0 = greedy).
    ///   - timeout: Maximum time allowed for inference.
    /// - Returns: The generated text.
    /// - Throws: `ModelError` on failure or timeout.
    func generate(
        prompt: String,
        maxTokens: Int = 256,
        temperature: Float = 0,
        timeout: TimeInterval = 10
    ) throws -> String {
        guard let model = self.model, let ctx = self.defaultCtx else {
            throw ModelError.modelNotLoaded
        }

        let deadline = Date().addingTimeInterval(timeout)

        return try queue.sync {
            // Tokenize input.
            let vocab = llama_model_get_vocab(model)
            let promptBytes = Array(prompt.utf8)
            let maxInputTokens = promptBytes.count + 1
            var tokens = [llama_token](repeating: 0, count: maxInputTokens)
            let nTokens = llama_tokenize(vocab, promptBytes, Int32(promptBytes.count),
                                          &tokens, Int32(maxInputTokens), true, true)
            guard nTokens > 0 else {
                throw ModelError.inferenceFailed("Tokenization failed")
            }
            tokens = Array(tokens.prefix(Int(nTokens)))
            let promptStart = Date()

            // Clear KV cache.
            llama_memory_clear(llama_get_memory(ctx), true)

            // Create batch and evaluate prompt tokens.
            var batch = llama_batch_init(Int32(tokens.count + maxTokens), 0, 1)
            defer { llama_batch_free(batch) }

            for (i, token) in tokens.enumerated() {
                let idx = Int(batch.n_tokens)
                batch.token[idx] = token
                batch.pos[idx] = Int32(i)
                batch.n_seq_id[idx] = 1
                batch.seq_id[idx]![0] = 0
                batch.logits[idx] = 0
                batch.n_tokens += 1
            }
            batch.logits[Int(batch.n_tokens - 1)] = 1 // Enable logits for last token

            guard llama_decode(ctx, batch) == 0 else {
                throw ModelError.inferenceFailed("Initial decode failed")
            }
            let promptMs = Int(Date().timeIntervalSince(promptStart) * 1000)

            // Autoregressive generation.
            var outputTokens: [llama_token] = []
            var curPos = batch.n_tokens

            // Create sampler once, reuse for all tokens.
            let sampler: UnsafeMutablePointer<llama_sampler>
            if temperature <= 0 {
                sampler = llama_sampler_init_greedy()
            } else {
                sampler = llama_sampler_init_temp(temperature)
            }
            defer { llama_sampler_free(sampler) }

            for _ in 0..<maxTokens {
                // Check timeout.
                if Date() > deadline {
                    throw ModelError.timeout
                }

                // Sample next token.
                let logits = llama_get_logits_ith(ctx, batch.n_tokens - 1)!
                let nVocab = llama_vocab_n_tokens(vocab)

                var candidates = (0..<nVocab).map { i in
                    llama_token_data(id: i, logit: logits[Int(i)], p: 0)
                }

                var candidatesP = llama_token_data_array(
                    data: &candidates,
                    size: Int(nVocab),
                    selected: -1,
                    sorted: false
                )

                let nextToken: llama_token
                if temperature <= 0 {
                    nextToken = llama_sampler_sample(sampler, ctx, -1)
                } else {
                    llama_sampler_apply(sampler, &candidatesP)
                    nextToken = candidatesP.data[0].id
                }

                // Check for EOS.
                if llama_vocab_is_eog(vocab, nextToken) {
                    break
                }

                outputTokens.append(nextToken)

                // Prepare next batch.
                batch.n_tokens = 0
                let idx = 0
                batch.token[idx] = nextToken
                batch.pos[idx] = curPos
                batch.n_seq_id[idx] = 1
                batch.seq_id[idx]![0] = 0
                batch.logits[idx] = 1
                batch.n_tokens = 1
                curPos += 1

                guard llama_decode(ctx, batch) == 0 else {
                    throw ModelError.inferenceFailed("Decode failed at position \(curPos)")
                }
            }

            // Detokenize output.
            let totalMs = Int(Date().timeIntervalSince(promptStart) * 1000)
            let genTokens = outputTokens.count
            let tps = totalMs > 0 ? Double(genTokens) / (Double(totalMs) / 1000.0) : 0
            DebugLog.log(.model, "Inference: prompt=\(Int(nTokens))tok/\(promptMs)ms gen=\(genTokens)tok/\(totalMs - promptMs)ms total=\(totalMs)ms (\(String(format: "%.1f", tps)) tok/s)")
            return detokenize(tokens: outputTokens, vocab: vocab)
        }
    }

    // MARK: - Private Helpers

    private func createContext() {
        guard let model = self.model else { return }

        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = 512
        ctxParams.n_batch = 512

        self.defaultCtx = llama_init_from_model(model, ctxParams)
    }

    private func unloadInternal() {
        if let ctx = defaultCtx {
            llama_free(ctx)
            defaultCtx = nil
        }
        if let adapter = currentAdapter {
            llama_adapter_lora_free(adapter)
            currentAdapter = nil
        }
        if let mdl = model {
            llama_model_free(mdl)
            model = nil
        }
        currentModelPath = nil
        currentAdapterPath = nil
    }

    private func detokenize(tokens: [llama_token], vocab: OpaquePointer?) -> String {
        guard let vocab = vocab else { return "" }
        var result = ""
        var buf = [CChar](repeating: 0, count: 256)

        for token in tokens {
            let n = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, true)
            if n > 0 {
                result += String(cString: buf.prefix(Int(n)) + [0])
            }
        }
        return result
    }
}
