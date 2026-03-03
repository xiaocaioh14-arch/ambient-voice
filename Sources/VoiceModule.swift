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
    func onHotkeyPressed() {
        guard state == .idle else { return }

        // Pin the frontmost app before we start recording
        pinnedApp = TextInjector.frontmostApp()
        DebugLog.log(.voice, "Recording started, target app: \(pinnedApp?.appName ?? "unknown")")

        state = .preparing
        onStateChange?(.preparing)

        Task {
            do {
                let voiceSession = VoiceSession()
                self.session = voiceSession
                try await voiceSession.start()

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

        let result = await session.stop()
        self.session = nil

        guard !result.fullText.isEmpty, let app = pinnedApp else {
            state = .idle
            onStateChange?(.idle)
            return
        }

        // Pass to VoicePipeline for L1 -> L2 -> inject -> capture
        await VoicePipeline.process(result: result, appIdentity: app)

        DebugLog.log(.voice, "Pipeline complete for session")
        state = .idle
        onStateChange?(.idle)
        pinnedApp = nil
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
