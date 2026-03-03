import Foundation
import Combine

/// Hot-reloadable runtime configuration.
/// Watches ~/.we/runtime-config.json and publishes changes when the file is modified.
/// Subscribers can use either the Combine publisher or NotificationCenter.
@MainActor
final class RuntimeConfig: Sendable {
    static let didChangeNotification = Notification.Name("WERuntimeConfigDidChange")

    nonisolated let configURL: URL
    @MainActor private(set) var current: Values

    nonisolated(unsafe) private var fileSource: DispatchSourceFileSystemObject?
    nonisolated(unsafe) private var fileDescriptor: Int32 = -1

    private let subject = PassthroughSubject<Values, Never>()
    var publisher: AnyPublisher<Values, Never> { subject.eraseToAnyPublisher() }

    struct Values: Codable, Sendable {
        var logLevel: String
        var debugOverlay: Bool
        var polishEnabled: Bool?
        var featureFlags: [String: Bool]

        enum CodingKeys: String, CodingKey {
            case logLevel = "log_level"
            case debugOverlay = "debug_overlay"
            case polishEnabled = "polish_enabled"
            case featureFlags = "feature_flags"
        }

        static let `default` = Values(
            logLevel: "info",
            debugOverlay: false,
            polishEnabled: nil,
            featureFlags: [:]
        )
    }

    init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".we")
        self.configURL = dir.appendingPathComponent("runtime-config.json")
        self.current = Self.loadFromDisk(url: configURL)
        startWatching()
    }

    deinit {
        fileSource?.cancel()
        if fileDescriptor >= 0 { close(fileDescriptor) }
    }

    // MARK: - File watching

    private nonisolated func startWatching() {
        let url = configURL
        let fm = FileManager.default

        let dir = url.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            writeDefault(to: url)
        }

        let fd = Darwin.open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        fileDescriptor = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename],
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let newValues = Self.loadFromDisk(url: url)
            Task { @MainActor in
                self.current = newValues
                self.subject.send(newValues)
                NotificationCenter.default.post(
                    name: RuntimeConfig.didChangeNotification,
                    object: nil,
                    userInfo: ["values": newValues]
                )
            }
        }
        source.setCancelHandler {
            Darwin.close(fd)
        }
        source.resume()
        fileSource = source
    }

    // MARK: - Helpers

    private nonisolated static func loadFromDisk(url: URL) -> Values {
        guard let data = try? Data(contentsOf: url) else { return .default }
        return (try? JSONDecoder().decode(Values.self, from: data)) ?? .default
    }

    private nonisolated func writeDefault(to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(Values.default) {
            try? data.write(to: url)
        }
    }
}
