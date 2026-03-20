import Foundation

/// Per-app capture strategy configuration.
///
/// Different apps have different editing patterns -- e.g. Slack submits on Enter,
/// while a code editor uses Cmd+Enter or has no submit signal at all.
struct CaptureProfile: Codable, Sendable {

    /// Signal that indicates the user has finished editing and submitted text.
    enum SubmitSignal: String, Codable, Sendable {
        case enter          // Plain Enter key
        case cmdEnter       // Cmd+Enter
        case focusChange    // When user switches away from the app
        case none           // No submit signal -- rely on timeout only
    }

    let bundleID: String
    let submitSignal: SubmitSignal
    let captureTimeout: TimeInterval
    let enabled: Bool

    /// Default profile used for unknown apps.
    static let `default` = CaptureProfile(
        bundleID: "*",
        submitSignal: .enter,
        captureTimeout: 30,
        enabled: true
    )

    /// Built-in profiles for common apps.
    static let builtIn: [CaptureProfile] = [
        // Terminal: Cmd+Enter (Enter executes commands)
        CaptureProfile(bundleID: "com.apple.Terminal", submitSignal: .cmdEnter, captureTimeout: 30, enabled: true),
        // iTerm2: Cmd+Enter
        CaptureProfile(bundleID: "com.googlecode.iterm2", submitSignal: .cmdEnter, captureTimeout: 30, enabled: true),
        // Ghostty: Enter (edit-detection mode handles capture via AX buffer)
        CaptureProfile(bundleID: "com.mitchellh.ghostty", submitSignal: .enter, captureTimeout: 30, enabled: true),
        // WeChat: Enter submits messages
        CaptureProfile(bundleID: "com.tencent.xinWeChat", submitSignal: .enter, captureTimeout: 15, enabled: true),
        // Slack: Enter submits messages
        CaptureProfile(bundleID: "com.tinyspeck.slackmacgap", submitSignal: .enter, captureTimeout: 15, enabled: true),
        // Messages: Enter submits
        CaptureProfile(bundleID: "com.apple.MobileSMS", submitSignal: .enter, captureTimeout: 15, enabled: true),
        // Telegram: Enter submits
        CaptureProfile(bundleID: "ru.keepcoder.Telegram", submitSignal: .enter, captureTimeout: 15, enabled: true),
        // Notes: focus change (no submit signal)
        CaptureProfile(bundleID: "com.apple.Notes", submitSignal: .focusChange, captureTimeout: 60, enabled: true),
        // TextEdit: focus change
        CaptureProfile(bundleID: "com.apple.TextEdit", submitSignal: .focusChange, captureTimeout: 60, enabled: true),
        // VS Code: Cmd+Enter in some contexts
        CaptureProfile(bundleID: "com.microsoft.VSCode", submitSignal: .cmdEnter, captureTimeout: 30, enabled: true),
        // Xcode
        CaptureProfile(bundleID: "com.apple.dt.Xcode", submitSignal: .cmdEnter, captureTimeout: 30, enabled: true),
        // Safari
        CaptureProfile(bundleID: "com.apple.Safari", submitSignal: .enter, captureTimeout: 30, enabled: true),
        // Chrome
        CaptureProfile(bundleID: "com.google.Chrome", submitSignal: .enter, captureTimeout: 30, enabled: true),
    ]

    /// Look up the capture profile for a given bundle ID.
    static func profile(for bundleID: String) -> CaptureProfile {
        builtIn.first { $0.bundleID == bundleID } ?? .default
    }
}
