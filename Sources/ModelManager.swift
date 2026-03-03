import Foundation
import CryptoKit

/// Manages downloading, verifying, and tracking GGUF model files.
///
/// Models live in ~/.we/models/. On launch the app calls `isReady` to decide
/// whether to show the setup window, and `ensureModels()` to download anything
/// that is missing or outdated.
@MainActor
final class ModelManager: ObservableObject {

    // MARK: - Published state

    @Published var downloadProgress: Double = 0  // 0…1
    @Published var downloadStatus: String = ""
    @Published var isDownloading = false

    // MARK: - Paths

    static let modelsDir: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".we")
            .appendingPathComponent("models")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    var baseModelURL: URL { Self.modelsDir.appendingPathComponent("qwen3-0.6b.gguf") }
    var defaultAdapterURL: URL { Self.modelsDir.appendingPathComponent("sa-adapter.gguf") }

    func adapterURL(for filename: String) -> URL {
        Self.modelsDir.appendingPathComponent(filename)
    }

    // MARK: - Manifest

    struct Manifest: Codable, Sendable {
        var baseModel: ModelEntry
        var adapter: ModelEntry

        enum CodingKeys: String, CodingKey {
            case baseModel = "base_model"
            case adapter
        }
    }

    struct ModelEntry: Codable, Sendable {
        var file: String
        var sha256: String
        var size: Int64
    }

    // MARK: - Readiness

    /// Returns true when both the base model and default adapter exist on disk.
    var isReady: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: baseModelURL.path)
            && fm.fileExists(atPath: defaultAdapterURL.path)
    }

    /// Verify local files against a manifest. Returns filenames that are
    /// missing or have a hash mismatch.
    func staleEntries(manifest: Manifest) -> [ModelEntry] {
        var stale: [ModelEntry] = []
        let entries: [(ModelEntry, URL)] = [
            (manifest.baseModel, adapterURL(for: manifest.baseModel.file)),
            (manifest.adapter, adapterURL(for: manifest.adapter.file)),
        ]
        for (entry, url) in entries {
            guard FileManager.default.fileExists(atPath: url.path) else {
                stale.append(entry)
                continue
            }
            if let hash = sha256(of: url), hash != entry.sha256 {
                stale.append(entry)
            }
        }
        return stale
    }

    // MARK: - Manifest fetch

    func fetchManifest(from config: WEConfig) async throws -> Manifest {
        guard let url = URL(string: config.downloads.manifest) else {
            throw ModelError.invalidURL(config.downloads.manifest)
        }
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode(Manifest.self, from: data)
    }

    // MARK: - Download

    /// Download all required models using URLs from config.
    /// Reports progress through published properties.
    func ensureModels(config: WEConfig) async throws {
        isDownloading = true
        defer { isDownloading = false }

        if !FileManager.default.fileExists(atPath: baseModelURL.path) {
            try await download(
                from: config.downloads.baseModel,
                to: baseModelURL,
                label: "base model"
            )
        }

        if !FileManager.default.fileExists(atPath: defaultAdapterURL.path) {
            try await download(
                from: config.downloads.adapter,
                to: defaultAdapterURL,
                label: "adapter"
            )
        }

        downloadStatus = "Models ready"
        downloadProgress = 1
        DebugLog.log(.model, "All models verified and ready")
    }

    /// Download a single file with progress and resume support.
    private func download(from urlString: String, to destination: URL, label: String) async throws {
        guard let url = URL(string: urlString) else {
            throw ModelError.invalidURL(urlString)
        }

        downloadStatus = "Downloading \(label)..."
        DebugLog.log(.model, "Starting download: \(label) from \(urlString)")

        // Check for partial download to support resume
        let partialURL = destination.appendingPathExtension("part")
        var request = URLRequest(url: url)
        var existingSize: Int64 = 0

        if FileManager.default.fileExists(atPath: partialURL.path),
           let attrs = try? FileManager.default.attributesOfItem(atPath: partialURL.path),
           let size = attrs[.size] as? Int64, size > 0 {
            existingSize = size
            request.setValue("bytes=\(size)-", forHTTPHeaderField: "Range")
            DebugLog.log(.model, "Resuming \(label) from byte \(size)")
        }

        let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)

        let httpResponse = response as? HTTPURLResponse
        let totalSize: Int64
        if httpResponse?.statusCode == 206, let contentRange = httpResponse?.value(forHTTPHeaderField: "Content-Range") {
            // Parse total from "bytes start-end/total"
            if let slashIdx = contentRange.lastIndex(of: "/"),
               let total = Int64(contentRange[contentRange.index(after: slashIdx)...]) {
                totalSize = total
            } else {
                totalSize = existingSize + (response.expectedContentLength > 0 ? response.expectedContentLength : 0)
            }
        } else {
            // No resume or server doesn't support range — start fresh
            existingSize = 0
            try? FileManager.default.removeItem(at: partialURL)
            totalSize = response.expectedContentLength > 0 ? response.expectedContentLength : 0
        }

        // Open file for writing
        if !FileManager.default.fileExists(atPath: partialURL.path) {
            FileManager.default.createFile(atPath: partialURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: partialURL)
        handle.seekToEndOfFile()

        var received = existingSize
        let bufferSize = 256 * 1024  // 256 KB chunks
        var buffer = Data()
        buffer.reserveCapacity(bufferSize)

        for try await byte in asyncBytes {
            buffer.append(byte)
            if buffer.count >= bufferSize {
                handle.write(buffer)
                received += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if totalSize > 0 {
                    downloadProgress = Double(received) / Double(totalSize)
                }
            }
        }
        // Flush remaining
        if !buffer.isEmpty {
            handle.write(buffer)
            received += Int64(buffer.count)
        }
        try handle.close()

        downloadProgress = 1
        DebugLog.log(.model, "Download complete: \(label) (\(received) bytes)")

        // Move partial to final destination
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partialURL, to: destination)
    }

    // MARK: - Hash verification

    /// Compute SHA256 hex digest of a file.
    func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: 1024 * 1024)  // 1 MB
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        try? handle.close()
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Verify a local model file against an expected SHA256 hash.
    func verify(file: URL, expectedHash: String) -> Bool {
        guard let hash = sha256(of: file) else { return false }
        let matches = hash == expectedHash
        if !matches {
            DebugLog.log(.model, "Hash mismatch for \(file.lastPathComponent): expected \(expectedHash), got \(hash)", level: .warning)
        }
        return matches
    }

    // MARK: - Update check

    /// Check if newer models are available based on manifest.
    func checkForUpdates(config: WEConfig) async -> Bool {
        guard let manifest = try? await fetchManifest(from: config) else {
            return false
        }
        return !staleEntries(manifest: manifest).isEmpty
    }

    // MARK: - Errors

    enum ModelError: Error, LocalizedError {
        case invalidURL(String)
        case hashMismatch(file: String, expected: String, actual: String)
        case downloadFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidURL(let url):
                return "Invalid model URL: \(url)"
            case .hashMismatch(let file, let expected, let actual):
                return "Hash mismatch for \(file): expected \(expected), got \(actual)"
            case .downloadFailed(let reason):
                return "Download failed: \(reason)"
            }
        }
    }
}
