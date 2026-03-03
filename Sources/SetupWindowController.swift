import Foundation
import AppKit
import SwiftUI

/// Controls the first-run setup window shown when models need to be downloaded.
///
/// Integration: called from WEApp on launch. Checks ModelManager.isReady;
/// if not ready, shows setup window and triggers model downloads.
@MainActor
final class SetupWindowController {
    private var window: NSWindow?
    private let modelManager: ModelManager

    init(modelManager: ModelManager = ModelManager()) {
        self.modelManager = modelManager
    }

    /// Show setup window only if models are missing.
    func showIfNeeded() {
        if !modelManager.isReady {
            show()
        }
    }

    func show() {
        let view = SetupView(modelManager: modelManager) { [weak self] in
            self?.dismiss()
        }
        let hostingController = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "WE - Setup"
        window.setContentSize(NSSize(width: 500, height: 350))
        window.styleMask = [.titled, .closable]
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        self.window = window

        // Start download via ModelManager.
        Task {
            let config = WEConfig.load()
            try? await modelManager.ensureModels(config: config)
        }
    }

    func dismiss() {
        window?.close()
        window = nil
    }
}

// MARK: - SwiftUI View

struct SetupView: View {
    @ObservedObject var modelManager: ModelManager
    let onDismiss: @MainActor () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("WE Setup")
                .font(.title2).bold()

            Text("Downloading required models...")
                .foregroundColor(.secondary)

            ProgressView(value: modelManager.downloadProgress)
                .progressViewStyle(.linear)

            Text(modelManager.downloadStatus)
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()

            if modelManager.isReady {
                Button("Get Started") { onDismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(30)
    }
}
