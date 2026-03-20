import SwiftUI

@main
struct WEApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            AppMenu(delegate: appDelegate)
        } label: {
            Image(systemName: appDelegate.isListening ? "mic.fill" : "mic")
        }
        Settings {
            EmptyView()
        }
    }
}

// MARK: - AppDelegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    @Published var isListening = false
    @Published var statusText = "Ready"

    @Published var isMeetingActive = false

    private let moduleManager = ModuleManager()
    private var config: WEConfig!
    private var runtimeConfig: RuntimeConfig!
    private var debugLog: DebugLog!
    private var voiceModule: VoiceModule!
    private var meetingModule: MeetingModule!
    private let permissionManager = PermissionManager()
    private var updaterService: UpdaterService!
    private var localModelClient: LocalModelClient!

    static let configDir: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".we")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        debugLog = DebugLog()
        config = WEConfig.load()
        runtimeConfig = RuntimeConfig()
        updaterService = UpdaterService()

        DebugLog.log(.config, "WE launched, config loaded")

        // Initialize local model client and load model if polish is enabled
        localModelClient = LocalModelClient()
        if config.polish?.enabled == true && config.polish?.type == .local {
            do {
                try localModelClient.loadModel(filename: "qwen3-0.6b.gguf")
                DebugLog.log(.model, "Qwen3 0.6B loaded for L2 polish")
            } catch {
                DebugLog.log(.model, "Failed to load Qwen3 0.6B: \(error)", level: .error)
            }
        }

        // Configure the voice pipeline with polish + correction
        VoicePipeline.configure(config: config, localClient: localModelClient)
        DebugLog.log(.pipeline, "VoicePipeline configured")

        let context = ShellContext(
            configDir: Self.configDir,
            runtimeConfig: runtimeConfig,
            debugLog: debugLog
        )

        // Register meeting module
        meetingModule = MeetingModule(context: context)
        meetingModule.onStateChange = { [weak self] state in
            guard let self else { return }
            self.isMeetingActive = state == .recording
            if state == .recording {
                self.statusText = "Meeting..."
            } else if self.voiceModule.state == .idle {
                self.statusText = "Ready"
            }
        }
        moduleManager.register(meetingModule)

        // Register voice module — it owns its own GlobalHotKey
        voiceModule = VoiceModule(context: context)
        voiceModule.meetingModule = meetingModule
        voiceModule.onStateChange = { [weak self] state in
            guard let self else { return }
            switch state {
            case .idle:
                self.isListening = false
                if !self.isMeetingActive {
                    self.statusText = "Ready"
                }
            case .preparing:
                self.isListening = true
                self.statusText = "Preparing..."
            case .recording:
                self.isListening = true
                self.statusText = "Listening..."
            case .processing:
                self.isListening = false
                self.statusText = "Processing..."
            }
        }
        moduleManager.register(voiceModule)

        // Check permissions
        permissionManager.checkAll()
        if !permissionManager.allGranted {
            DebugLog.log(.permission, "Permissions not yet granted, will prompt user")
        }

        // Check model readiness
        let modelManager = ModelManager()
        if !modelManager.isReady {
            DebugLog.log(.model, "Models not ready, showing setup window")
            let setup = SetupWindowController(modelManager: modelManager)
            setup.show()
        }

        // Activate modules
        Task {
            try? await moduleManager.activate("Meeting")
            DebugLog.log(.meeting, "MeetingModule activated")
            try? await moduleManager.activate("Voice")
            DebugLog.log(.voice, "VoiceModule activated")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task {
            await moduleManager.deactivateAll()
        }
    }

    // MARK: - Menu actions

    func toggleListening() {
        if voiceModule.state == .idle {
            voiceModule.onHotkeyPressed()
        } else if voiceModule.state == .recording {
            voiceModule.onHotkeyReleased()
        }
    }

    func toggleMeeting() {
        meetingModule.toggle()
    }

    func exportMeeting() {
        if let path = meetingModule.exportLastMeeting() {
            DebugLog.log(.meeting, "Meeting exported to \(path)")
        }
    }

    func showPermissions() {
        let guide = PermissionGuideController(permissionManager: permissionManager)
        guide.show()
    }

    func checkForUpdates() {
        updaterService.checkForUpdates()
    }

    func quit() {
        Task {
            await moduleManager.deactivateAll()
            NSApplication.shared.terminate(nil)
        }
    }
}

// MARK: - Menu

struct AppMenu: View {
    @ObservedObject var delegate: AppDelegate

    var body: some View {
        Text(delegate.statusText)
            .font(.caption)

        Divider()

        Button(delegate.isListening ? "Stop Listening" : "Start Listening") {
            delegate.toggleListening()
        }
        .keyboardShortcut("l", modifiers: [.command])

        Divider()

        Button(delegate.isMeetingActive ? "End Meeting" : "Start Meeting") {
            delegate.toggleMeeting()
        }
        .keyboardShortcut("m", modifiers: [.command])

        Button("Export Meeting") {
            delegate.exportMeeting()
        }

        Divider()

        Button("Check for Updates...") {
            delegate.checkForUpdates()
        }

        Button("Permissions...") {
            delegate.showPermissions()
        }

        Divider()

        Button("Quit WE") {
            delegate.quit()
        }
        .keyboardShortcut("q", modifiers: [.command])
    }
}
