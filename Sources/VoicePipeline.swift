import Foundation

/// Result of a full voice pipeline run.
struct PipelineResult {
    let rawText: String
    let l1Text: String
    let polishedText: String
    let injected: Bool
    let polishBackend: PolishClient.BackendType?
    let polishLatencyMs: Int
}

/// Orchestrates post-recording processing: L1 correction -> L2 polish -> text injection
/// -> correction capture -> history persistence.
///
/// Each step is modular: failures in polish fall back to L1 output, failures in
/// injection are logged but don't block history saving.
enum VoicePipeline {

    // MARK: - Shared state

    /// Shared PolishClient instance. Initialized once from config.
    /// VoiceModule or WEApp should call `configure(config:localClient:)` at startup.
    @MainActor private(set) static var polishClient: PolishClient?
    @MainActor private(set) static var correctionCapture: CorrectionCapture?

    /// Configure the pipeline with runtime dependencies.
    @MainActor
    static func configure(config: WEConfig, localClient: LocalModelClient) {
        polishClient = PolishClient(weConfig: config, localClient: localClient)
        correctionCapture = CorrectionCapture()
    }

    // MARK: - Public API

    /// Run the full processing pipeline for a completed voice session.
    ///
    /// Steps:
    /// 1. L1 deterministic correction (AlternativeSwap)
    /// 2. L2 polish (PolishClient -- may call local model or HTTP backend)
    /// 3. Inject final text into the target application
    /// 4. Start correction capture window
    /// 5. Save session to voice history
    ///
    /// - Parameters:
    ///   - result: The transcription result from VoiceSession.
    ///   - appIdentity: The pinned target application.
    /// - Returns: Structured pipeline result.
    @MainActor @discardableResult
    static func process(result: TranscriptionResult, appIdentity: AppIdentity) async -> PipelineResult {
        let sessionID = UUID().uuidString
        DebugLog.log(.pipeline, "Pipeline started for session \(sessionID)")

        // Step 1: L1 deterministic correction
        let correctionHistory = CorrectionStore.shared.loadHistory()
        let l1Text = AlternativeSwap.apply(
            rawText: result.fullText,
            words: result.words,
            correctionHistory: correctionHistory
        )
        DebugLog.log(.pipeline, "L1: \"\(result.fullText)\" -> \"\(l1Text)\"")

        // Step 2: L2 polish
        let polishResult: PolishClient.PolishResult
        if let client = polishClient {
            let wordConfidences = result.words.map { $0.confidence }
            let request = PolishClient.PolishRequest(
                text: l1Text,
                wordConfidences: wordConfidences,
                appBundleID: appIdentity.bundleID
            )
            polishResult = await client.polish(request)
            DebugLog.log(.pipeline, "L2: \"\(l1Text)\" -> \"\(polishResult.text)\" (\(polishResult.latencyMs)ms)")
        } else {
            // No polish client configured -- pass through L1 output
            polishResult = PolishClient.PolishResult(text: l1Text, backend: nil, latencyMs: 0)
            DebugLog.log(.pipeline, "L2: skipped (no polish client)")
        }

        let finalText = polishResult.text

        // Step 3: Inject into target app
        let injected: Bool
        if !finalText.isEmpty {
            TextInjector.insert(finalText, into: appIdentity)
            injected = true
            DebugLog.log(.pipeline, "Injected \(finalText.count) chars into \(appIdentity.appName)")
        } else {
            injected = false
            DebugLog.log(.pipeline, "Skipped injection: empty text")
        }

        // Step 4: Start correction capture
        if injected {
            correctionCapture?.startWindow(
                insertedText: finalText,
                rawText: result.fullText,
                app: appIdentity
            )
        }

        // Step 5: Save to voice history
        let historyEntry = VoiceHistoryEntry(
            sessionID: sessionID,
            timestamp: Date(),
            rawText: result.fullText,
            l1Text: l1Text,
            polishedText: polishResult.backend != nil ? polishResult.text : nil,
            appBundleID: appIdentity.bundleID,
            appName: appIdentity.appName,
            wordCount: result.words.count,
            duration: result.words.last.map { $0.timestamp + $0.duration } ?? 0,
            polished: polishResult.backend != nil
        )
        VoiceHistory.shared.save(entry: historyEntry)
        DebugLog.log(.pipeline, "Session \(sessionID) saved to history")

        return PipelineResult(
            rawText: result.fullText,
            l1Text: l1Text,
            polishedText: polishResult.text,
            injected: injected,
            polishBackend: polishResult.backend,
            polishLatencyMs: polishResult.latencyMs
        )
    }
}
