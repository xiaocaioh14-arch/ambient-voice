import Foundation
import AVFoundation
import AppKit

@MainActor
final class PermissionManager: ObservableObject {
    enum PermissionStatus: Sendable {
        case granted, denied, notDetermined
    }

    @Published var accessibilityStatus: PermissionStatus = .notDetermined
    @Published var microphoneStatus: PermissionStatus = .notDetermined

    var allGranted: Bool { accessibilityStatus == .granted && microphoneStatus == .granted }

    private var pollTimer: Timer?

    func checkAll() {
        checkAccessibility()
        checkMicrophone()
    }

    func checkAccessibility() {
        accessibilityStatus = AXIsProcessTrusted() ? .granted : .denied
    }

    func checkMicrophone() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphoneStatus = .granted
        case .denied, .restricted:
            microphoneStatus = .denied
        case .notDetermined:
            microphoneStatus = .notDetermined
        @unknown default:
            microphoneStatus = .notDetermined
        }
    }

    @discardableResult
    func requestMicrophone() async -> Bool {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        checkMicrophone()
        return granted
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkAll()
            }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}
