import Foundation
import Sparkle

@MainActor
final class UpdaterService {
    private let updaterController: SPUStandardUpdaterController

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    /// Check for app updates (triggered from menu bar).
    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    /// The updater instance for binding to SwiftUI menu items.
    var updater: SPUUpdater {
        updaterController.updater
    }

    /// Check for model updates via ModelManager.
    func checkForModelUpdates() async {
        // Placeholder: compare local manifest with remote manifest.
        // When ModelManager is fully implemented, delegate to it.
    }
}
