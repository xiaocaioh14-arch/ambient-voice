import Foundation
import AppKit
import SwiftUI

@MainActor
final class PermissionGuideController {
    private var window: NSWindow?
    private let permissionManager: PermissionManager

    init(permissionManager: PermissionManager) {
        self.permissionManager = permissionManager
    }

    func showIfNeeded() {
        permissionManager.checkAll()
        if !permissionManager.allGranted {
            show()
        }
    }

    func show() {
        let view = PermissionGuideView(manager: permissionManager) { [weak self] in
            self?.dismiss()
        }
        let hostingController = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "WE - Permission Setup"
        window.setContentSize(NSSize(width: 450, height: 300))
        window.styleMask = [.titled, .closable]
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window

        permissionManager.startPolling()
    }

    func dismiss() {
        permissionManager.stopPolling()
        window?.close()
        window = nil
    }
}

struct PermissionGuideView: View {
    @ObservedObject var manager: PermissionManager
    let onDismiss: @MainActor () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("WE Permissions Setup")
                .font(.title2)
                .bold()

            HStack {
                Image(systemName: manager.accessibilityStatus == .granted
                      ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundColor(manager.accessibilityStatus == .granted ? .green : .orange)
                Text("Accessibility")
                Spacer()
                if manager.accessibilityStatus != .granted {
                    Button("Open Settings") { manager.openAccessibilitySettings() }
                }
            }

            HStack {
                Image(systemName: manager.microphoneStatus == .granted
                      ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundColor(manager.microphoneStatus == .granted ? .green : .orange)
                Text("Microphone")
                Spacer()
                if manager.microphoneStatus != .granted {
                    Button("Request Access") {
                        Task { await manager.requestMicrophone() }
                    }
                }
            }

            Spacer()

            Button("Continue") { onDismiss() }
                .disabled(!manager.allGranted)
                .buttonStyle(.borderedProminent)
        }
        .padding(30)
    }
}
