import Foundation
import AppKit

/// Orchestrates push-to-talk voice recording sessions.
///
/// Responds to GlobalHotKey events: press starts a VoiceSession, release stops
/// it and passes the transcription result downstream to VoicePipeline.
/// Pins the frontmost application identity at recording start so that text
/// injection targets the correct app even if the user switches windows.
@MainActor
final class VoiceModule: WEModule {
    let name = "Voice"
    private(set) var isActive = false

    // MARK: - State machine

    enum State {
        case idle
        case preparing
        case recording
        case processing
    }

    private(set) var state: State = .idle
    var onStateChange: ((State) -> Void)?

    // MARK: - Dependencies

    private let context: ShellContext
    private let hotKey = GlobalHotKey()
    private var session: VoiceSession?
    private var pinnedApp: AppIdentity?
    private var pendingStop = false

    init(context: ShellContext) {
        self.context = context
    }

    // MARK: - WEModule lifecycle

    /// Optional meeting module reference for double-tap routing.
    var meetingModule: MeetingModule?

    func activate() async throws {
        isActive = true
        hotKey.onEvent = { [weak self] event in
            guard let self = self else { return }
            Task { @MainActor in
                switch event {
                case .pressed:
                    self.onHotkeyPressed()
                case .released:
                    self.onHotkeyReleased()
                case .doubleTap:
                    self.meetingModule?.toggle()
                }
            }
        }
        hotKey.start()
        DebugLog.log(.voice, "VoiceModule activated")
    }

    func deactivate() async {
        hotKey.stop()
        hotKey.onEvent = nil

        if state != .idle {
            await forceStop()
        }
        isActive = false
        DebugLog.log(.voice, "VoiceModule deactivated")
    }

    // MARK: - Hotkey handling

    /// Called when hotkey is pressed (after debounce).
    /// Screen context captured concurrently with voice recording.
    private var capturedScreenContext: ScreenContext?
    private var screenCaptureTask: Task<Void, Never>?

    func onHotkeyPressed() {
        guard state == .idle else { return }

        // Pin the frontmost app before we start recording
        pinnedApp = TextInjector.frontmostApp()
        DebugLog.log(.voice, "Recording started, target app: \(pinnedApp?.appName ?? "unknown")")

        state = .preparing
        onStateChange?(.preparing)
        capturedScreenContext = nil
        screenCaptureTask = nil

        let config = WEConfig.load()

        Task {
            do {
                let voiceSession = VoiceSession()

                // Enable audio saving for distillation if configured
                if config.distillation?.saveAudio == true {
                    voiceSession.saveAudio = true
                }

                self.session = voiceSession

                // Inject config keywords immediately, start recording first.
                // Screen OCR runs in parallel — its keywords are injected when ready.
                voiceSession.contextualStrings = config.keywords ?? []

                try await voiceSession.start()

                // Screen capture runs in parallel after recording has started.
                if let scConfig = config.screenContext, scConfig.enabled {
                    self.screenCaptureTask?.cancel()
                    self.screenCaptureTask = Task {
                        let ctx = await ScreenContextProvider.capture(config: scConfig)
                        await MainActor.run {
                            self.capturedScreenContext = ctx
                        }
                    }
                }

                // Session is now recording — check if release arrived while preparing
                if pendingStop {
                    pendingStop = false
                    await stopRecording()
                } else {
                    state = .recording
                    onStateChange?(.recording)
                }
            } catch {
                DebugLog.log(.voice, "Failed to start session: \(error)", level: .error)
                state = .idle
                onStateChange?(.idle)
            }
        }
    }

    /// Called when hotkey is released.
    func onHotkeyReleased() {
        switch state {
        case .preparing:
            // User released before recording started — queue stop
            pendingStop = true
        case .recording:
            Task { await stopRecording() }
        default:
            break
        }
    }

    // MARK: - Session lifecycle

    private func stopRecording() async {
        state = .processing
        onStateChange?(.processing)

        guard let session = session else {
            state = .idle
            onStateChange?(.idle)
            return
        }

        // Wait for screen capture to finish (if still running)
        await screenCaptureTask?.value
        screenCaptureTask = nil

        let result = await session.stop()
        let audioPath = session.savedAudioPath
        self.session = nil

        guard !result.fullText.isEmpty, let app = pinnedApp else {
            state = .idle
            onStateChange?(.idle)
            return
        }

        // Pass to VoicePipeline for L1 -> L2 -> inject -> capture
        await VoicePipeline.process(
            result: result,
            appIdentity: app,
            screenContext: capturedScreenContext,
            audioFilePath: audioPath
        )

        DebugLog.log(.voice, "Pipeline complete for session")
        state = .idle
        onStateChange?(.idle)
        pinnedApp = nil
        capturedScreenContext = nil
    }

    private func forceStop() async {
        if let session = session {
            _ = await session.stop()
        }
        session = nil
        state = .idle
        onStateChange?(.idle)
        pinnedApp = nil
        pendingStop = false
    }
}
