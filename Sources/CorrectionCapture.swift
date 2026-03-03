import Foundation
import AppKit
import ApplicationServices

/// Monitors user edits after text injection to capture corrections.
///
/// Data flow: TextInjector inserts -> CorrectionCapture monitors ->
/// CorrectionStore persists -> AlternativeSwap learns
final class CorrectionCapture {
    private var isMonitoring = false
    private var insertedText: String = ""
    private var rawText: String = ""
    private var targetApp: AppIdentity?
    private var profile: CaptureProfile?
    private var captureTimer: Timer?
    private var eventMonitor: Any?

    /// Start monitoring for user corrections after text injection.
    func startWindow(insertedText: String, rawText: String, app: AppIdentity) {
        self.insertedText = insertedText
        self.rawText = rawText
        self.targetApp = app
        self.profile = CaptureProfile.profile(for: app.bundleID)

        guard profile?.enabled == true else { return }

        isMonitoring = true

        // Monitor for submit signals (Enter / Cmd+Enter / focus change)
        startEventMonitoring()

        // Timeout fallback
        captureTimer = Timer.scheduledTimer(
            withTimeInterval: profile?.captureTimeout ?? 30,
            repeats: false
        ) { [weak self] _ in
            self?.endCapture(reason: "timeout")
        }
    }

    /// Stop monitoring without capturing (e.g. new session started).
    func cancel() {
        endCapture(reason: "cancelled")
    }

    // MARK: - Private

    private func startEventMonitoring() {
        guard let profile else { return }

        // Monitor key events for enter/cmdEnter submit signals.
        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.keyDown]
        ) { [weak self] event in
            self?.handleKeyEvent(event)
        }

        // For focusChange signal, also monitor app deactivation.
        if profile.submitSignal == .focusChange {
            NSWorkspace.shared.notificationCenter.addObserver(
                self,
                selector: #selector(appDidDeactivate(_:)),
                name: NSWorkspace.didDeactivateApplicationNotification,
                object: nil
            )
        }
    }

    private func handleKeyEvent(_ event: NSEvent) {
        guard let profile else { return }

        let isEnter = event.keyCode == 36 // Return key
        let isCmdHeld = event.modifierFlags.contains(.command)

        switch profile.submitSignal {
        case .enter:
            if isEnter && !isCmdHeld { captureAndCompare() }
        case .cmdEnter:
            if isEnter && isCmdHeld { captureAndCompare() }
        case .focusChange, .none:
            break
        }
    }

    @objc private func appDidDeactivate(_ notification: Notification) {
        guard let deactivatedApp = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              deactivatedApp.processIdentifier == targetApp?.processID else { return }
        captureAndCompare()
    }

    private func captureAndCompare() {
        guard let app = targetApp else { return }

        // Read current text from focused element via AX.
        let finalText = readFocusedText(pid: app.processID) ?? ""

        guard !finalText.isEmpty else {
            endCapture(reason: "empty final text")
            return
        }

        // Compare similarity.
        let similarity = Self.stringSimilarity(insertedText, finalText)
        let lengthRatio = Double(finalText.count) / max(Double(insertedText.count), 1)

        // Only capture if within reasonable bounds (actual correction, not rewrite).
        if similarity > 0.3 && similarity < 1.0 && lengthRatio > 0.5 && lengthRatio < 2.0 {
            let quality = similarity * min(lengthRatio, 1.0 / lengthRatio)

            let entry = CorrectionEntry(
                id: UUID().uuidString,
                timestamp: Date(),
                rawText: rawText,
                insertedText: insertedText,
                userFinalText: finalText,
                quality: quality,
                appBundleID: app.bundleID,
                appName: app.appName,
                metadata: nil
            )
            CorrectionStore.shared.save(entry)
        }

        endCapture(reason: "captured")
    }

    private func readFocusedText(pid: pid_t) -> String? {
        let appElement = AXUIElementCreateApplication(pid)
        var focusedElement: AnyObject?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        ) == .success else { return nil }

        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(
            focusedElement as! AXUIElement,
            kAXValueAttribute as CFString,
            &value
        ) == .success else { return nil }

        return value as? String
    }

    /// Character-level Jaccard similarity.
    private static func stringSimilarity(_ a: String, _ b: String) -> Double {
        let setA = Set(a)
        let setB = Set(b)
        let intersection = setA.intersection(setB).count
        let union = setA.union(setB).count
        return union > 0 ? Double(intersection) / Double(union) : 0
    }

    func endCapture(reason: String) {
        guard isMonitoring else { return }
        isMonitoring = false
        captureTimer?.invalidate()
        captureTimer = nil
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}
