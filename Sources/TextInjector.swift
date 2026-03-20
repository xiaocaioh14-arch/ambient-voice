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
    /// Apps where AX insertion doesn't work correctly — use clipboard directly.
    private static let clipboardOnlyBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
    ]

    /// Whether the given bundle ID is a terminal app (uses clipboard injection).
    static func isTerminalApp(_ bundleID: String) -> Bool {
        clipboardOnlyBundleIDs.contains(bundleID)
    }

    @discardableResult
    static func insert(_ text: String, into app: AppIdentity) -> InjectionMethod {
        // Some apps (terminals) don't respond well to AX value setting — go straight to clipboard.
        if !clipboardOnlyBundleIDs.contains(app.bundleID),
           tryAXInsertion(text, pid: app.processID) {
            DebugLog.log(.pipeline, "Text injected via AX into \(app.appName)")
            return .accessibility
        }

        clipboardInsertion(text, pid: app.processID)
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

        // Best method: set AXSelectedText to replace selection / insert at cursor.
        // This is the correct AX API for inserting text — it doesn't touch
        // the rest of the field content, just like a user typing.
        let selectedTextResult = AXUIElementSetAttributeValue(
            axElement,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )
        if selectedTextResult == .success {
            DebugLog.log(.pipeline, "AX insert via kAXSelectedTextAttribute succeeded")
            return true
        }

        // Fallback: only set the full value if the field is currently empty.
        // If the field has existing text, return false so we use clipboard
        // insertion (which naturally inserts at cursor position).
        var currentValue: AnyObject?
        let getResult = AXUIElementCopyAttributeValue(
            axElement,
            kAXValueAttribute as CFString,
            &currentValue
        )
        if getResult == .success, let currentText = currentValue as? String, !currentText.isEmpty {
            DebugLog.log(.pipeline, "AX selectedText failed, field has text — falling back to clipboard")
            return false
        }

        // Field is empty or unreadable — safe to set value directly.
        let setResult = AXUIElementSetAttributeValue(
            axElement,
            kAXValueAttribute as CFString,
            text as CFTypeRef
        )
        return setResult == .success
    }

    // MARK: - Clipboard Insertion

    /// Fallback: copy text to clipboard and simulate Cmd+V.
    ///
    /// Saves the current clipboard contents, pastes the new text, then restores
    /// the original clipboard after a short delay.
    ///
    /// - Parameter text: The text to insert via clipboard.
    private static func clipboardInsertion(_ text: String, pid: pid_t) {
        // Activate the target app to ensure it receives the paste event.
        if let runningApp = NSRunningApplication(processIdentifier: pid) {
            runningApp.activate()
            Thread.sleep(forTimeInterval: 0.15)
        }

        let pasteboard = NSPasteboard.general

        // Save current clipboard contents.
        let oldContents = pasteboard.string(forType: .string)

        // Set new text on clipboard.
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Try AX menu press first (works even with Secure Keyboard Entry),
        // fall back to CGEvent Cmd+V simulation.
        if !triggerPasteViaMenu(pid: pid) {
            DebugLog.log(.pipeline, "AX menu paste failed, falling back to CGEvent")
            simulatePasteViaCGEvent()
        }

        // Restore original clipboard after a delay to allow paste to complete.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let old = oldContents {
                pasteboard.clearContents()
                pasteboard.setString(old, forType: .string)
            }
        }
    }

    /// Trigger paste by pressing the Paste menu item via Accessibility API.
    /// This bypasses Secure Keyboard Entry restrictions that block CGEvent injection.
    private static func triggerPasteViaMenu(pid: pid_t) -> Bool {
        let appElement = AXUIElementCreateApplication(pid)

        var menuBarRef: AnyObject?
        guard AXUIElementCopyAttributeValue(appElement, kAXMenuBarAttribute as CFString, &menuBarRef) == .success else {
            return false
        }

        var menuBarItems: AnyObject?
        guard AXUIElementCopyAttributeValue(menuBarRef as! AXUIElement, kAXChildrenAttribute as CFString, &menuBarItems) == .success,
              let topMenus = menuBarItems as? [AXUIElement] else {
            return false
        }

        // Find "Edit" menu (handle English + Chinese localization).
        for topMenu in topMenus {
            var title: AnyObject?
            AXUIElementCopyAttributeValue(topMenu, kAXTitleAttribute as CFString, &title)
            guard let menuTitle = title as? String,
                  menuTitle == "Edit" || menuTitle == "编辑" else { continue }

            // Get the submenu children.
            var submenuRef: AnyObject?
            guard AXUIElementCopyAttributeValue(topMenu, kAXChildrenAttribute as CFString, &submenuRef) == .success,
                  let submenus = submenuRef as? [AXUIElement],
                  let editMenu = submenus.first else { continue }

            var menuItems: AnyObject?
            guard AXUIElementCopyAttributeValue(editMenu, kAXChildrenAttribute as CFString, &menuItems) == .success,
                  let items = menuItems as? [AXUIElement] else { continue }

            // Find "Paste" menu item.
            for item in items {
                var itemTitle: AnyObject?
                AXUIElementCopyAttributeValue(item, kAXTitleAttribute as CFString, &itemTitle)
                if let t = itemTitle as? String, t == "Paste" || t == "粘贴" {
                    let result = AXUIElementPerformAction(item, kAXPressAction as CFString)
                    DebugLog.log(.pipeline, "AX menu Paste press: \(result == .success ? "ok" : "failed")")
                    return result == .success
                }
            }
        }

        return false
    }

    /// Fallback: simulate Cmd+V via CGEvent.
    private static func simulatePasteViaCGEvent() {
        let source = CGEventSource(stateID: .combinedSessionState)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cgSessionEventTap)

        usleep(50_000)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cgSessionEventTap)
    }
}
