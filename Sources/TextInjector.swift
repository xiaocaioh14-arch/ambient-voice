import Foundation
import AppKit
import ApplicationServices

/// Identity of the target application for text injection.
struct AppIdentity {
    let bundleID: String
    let appName: String
    let processID: pid_t
}

/// Inserts transcribed text into the focused text field of a target application.
///
/// Uses Accessibility API as the primary insertion method (preserves clipboard),
/// falling back to clipboard + simulated Cmd+V when AX insertion fails.
final class TextInjector {

    enum InjectionMethod {
        case accessibility
        case clipboard
    }

    // MARK: - Public API

    /// Insert text into the focused element of the target app.
    ///
    /// Tries AX insertion first (requires Accessibility permission). If that fails,
    /// falls back to clipboard-based insertion with Cmd+V simulation.
    ///
    /// - Parameters:
    ///   - text: The text to insert.
    ///   - app: The target application identity (pinned at recording start).
    /// - Returns: The method that was used for insertion.
    @discardableResult
    static func insert(_ text: String, into app: AppIdentity) -> InjectionMethod {
        if tryAXInsertion(text, pid: app.processID) {
            DebugLog.log(.pipeline, "Text injected via AX into \(app.appName)")
            return .accessibility
        }

        clipboardInsertion(text)
        DebugLog.log(.pipeline, "Text injected via clipboard into \(app.appName)")
        return .clipboard
    }

    /// Get the frontmost application identity.
    ///
    /// Used by VoiceModule to pin app identity at recording start, ensuring text
    /// is injected into the correct app even if focus changes during recording.
    ///
    /// - Returns: The frontmost application identity, or nil if unavailable.
    static func frontmostApp() -> AppIdentity? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier else { return nil }
        return AppIdentity(
            bundleID: bundleID,
            appName: app.localizedName ?? "Unknown",
            processID: app.processIdentifier
        )
    }

    // MARK: - AX Insertion

    /// Try inserting text via Accessibility API.
    ///
    /// Gets the focused UI element of the target application and attempts to set
    /// its AXValue attribute. This works for most standard text fields and editors.
    ///
    /// - Parameters:
    ///   - text: The text to insert.
    ///   - pid: The process ID of the target application.
    /// - Returns: true if AX insertion succeeded, false otherwise.
    private static func tryAXInsertion(_ text: String, pid: pid_t) -> Bool {
        let appElement = AXUIElementCreateApplication(pid)

        // Get the focused UI element.
        var focusedElement: AnyObject?
        let focusResult = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )
        guard focusResult == .success, let element = focusedElement else {
            return false
        }

        let axElement = element as! AXUIElement

        // First try: set the value directly (works for simple text fields).
        let setResult = AXUIElementSetAttributeValue(
            axElement,
            kAXValueAttribute as CFString,
            text as CFTypeRef
        )
        if setResult == .success {
            return true
        }

        // Second try: use AXSelectedTextRange to insert at cursor position.
        // Get current value, selected range, and compose the new value.
        var currentValue: AnyObject?
        let getResult = AXUIElementCopyAttributeValue(
            axElement,
            kAXValueAttribute as CFString,
            &currentValue
        )

        if getResult == .success, let currentText = currentValue as? String {
            var selectedRange: AnyObject?
            let rangeResult = AXUIElementCopyAttributeValue(
                axElement,
                kAXSelectedTextRangeAttribute as CFString,
                &selectedRange
            )

            if rangeResult == .success, let rangeValue = selectedRange {
                var cfRange = CFRange(location: 0, length: 0)
                if AXValueGetValue(rangeValue as! AXValue, .cfRange, &cfRange) {
                    // Build new text with insertion at the selected range.
                    let nsText = currentText as NSString
                    let newText = nsText.replacingCharacters(
                        in: NSRange(location: cfRange.location, length: cfRange.length),
                        with: text
                    )
                    let finalResult = AXUIElementSetAttributeValue(
                        axElement,
                        kAXValueAttribute as CFString,
                        newText as CFTypeRef
                    )
                    return finalResult == .success
                }
            }
        }

        return false
    }

    // MARK: - Clipboard Insertion

    /// Fallback: copy text to clipboard and simulate Cmd+V.
    ///
    /// Saves the current clipboard contents, pastes the new text, then restores
    /// the original clipboard after a short delay.
    ///
    /// - Parameter text: The text to insert via clipboard.
    private static func clipboardInsertion(_ text: String) {
        let pasteboard = NSPasteboard.general

        // Save current clipboard contents.
        let oldContents = pasteboard.string(forType: .string)

        // Set new text on clipboard.
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Simulate Cmd+V keystroke.
        simulateKeyPress(keyCode: 9, flags: .maskCommand) // V key = keyCode 9

        // Restore original clipboard after a delay to allow paste to complete.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let old = oldContents {
                pasteboard.clearContents()
                pasteboard.setString(old, forType: .string)
            }
        }
    }

    /// Simulate a key press using CGEvent.
    ///
    /// Posts both key-down and key-up events with the specified modifier flags.
    ///
    /// - Parameters:
    ///   - keyCode: The virtual key code to simulate.
    ///   - flags: The modifier flags (e.g., .maskCommand for Cmd).
    private static func simulateKeyPress(keyCode: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        keyDown?.flags = flags
        keyDown?.post(tap: .cghidEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyUp?.flags = flags
        keyUp?.post(tap: .cghidEventTap)
    }
}
