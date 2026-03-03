import Foundation

/// Protocol defining a WE module's lifecycle.
/// Each module is a self-contained feature (Voice, Chat, etc.) that the shell
/// can activate/deactivate. Modules receive access to shared shell services
/// through the `ShellContext` provided at registration time.
@MainActor
protocol WEModule: AnyObject {
    var name: String { get }
    var isActive: Bool { get }
    func activate() async throws
    func deactivate() async
}

/// Shared services the shell provides to every module.
@MainActor
final class ShellContext: Sendable {
    let configDir: URL
    let runtimeConfig: RuntimeConfig
    let debugLog: DebugLog

    init(configDir: URL, runtimeConfig: RuntimeConfig, debugLog: DebugLog) {
        self.configDir = configDir
        self.runtimeConfig = runtimeConfig
        self.debugLog = debugLog
    }
}
