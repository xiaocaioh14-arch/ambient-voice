import Foundation

/// Manages registration and lifecycle of WE modules.
/// Currently only VoiceModule is registered, but the design supports
/// future modules (Chat, Files, Tools).
@MainActor
final class ModuleManager {
    private var modules: [String: WEModule] = [:]

    /// Register a module. Does not activate it.
    func register(_ module: WEModule) {
        modules[module.name] = module
    }

    /// Activate a module by name.
    func activate(_ name: String) async throws {
        guard let module = modules[name] else { return }
        if !module.isActive {
            try await module.activate()
        }
    }

    /// Deactivate a module by name.
    func deactivate(_ name: String) async {
        guard let module = modules[name] else { return }
        if module.isActive {
            await module.deactivate()
        }
    }

    /// Deactivate all active modules (used during shutdown).
    func deactivateAll() async {
        for module in modules.values where module.isActive {
            await module.deactivate()
        }
    }

    /// Get a module by name.
    func module(named name: String) -> WEModule? {
        modules[name]
    }

    /// All registered module names.
    var registeredNames: [String] {
        Array(modules.keys)
    }
}
