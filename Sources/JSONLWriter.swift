import Foundation

final class JSONLWriter: Sendable {
    private let fileURL: URL
    private let queue = DispatchQueue(label: "we.jsonl-writer", qos: .utility)
    private let maxFileSize: UInt64

    // Mutable state protected by `queue` — access only on queue.
    private nonisolated(unsafe) var fileHandle: FileHandle?

    init(fileURL: URL, maxFileSize: UInt64 = 50_000_000) {
        self.fileURL = fileURL
        self.maxFileSize = maxFileSize
    }

    /// Append a Codable item as a single JSON line.
    func append<T: Encodable>(_ item: T) {
        queue.async { [self] in
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]

            guard var data = try? encoder.encode(item) else { return }
            data.append(contentsOf: [0x0A]) // newline

            rotateIfNeeded()
            ensureFileHandle()

            guard let handle = fileHandle else { return }
            handle.seekToEndOfFile()
            handle.write(data)
        }
    }

    /// Read all entries from the file, skipping malformed lines.
    func readAll<T: Decodable>(as type: T.Type) -> [T] {
        queue.sync {
            guard let data = try? Data(contentsOf: fileURL) else { return [] }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            let lines = data.split(separator: 0x0A)
            return lines.compactMap { lineData in
                try? decoder.decode(T.self, from: Data(lineData))
            }
        }
    }

    private func ensureFileHandle() {
        if fileHandle != nil { return }

        let fm = FileManager.default
        let dir = fileURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil)
        }

        fileHandle = try? FileHandle(forWritingTo: fileURL)
    }

    private func rotateIfNeeded() {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? UInt64,
              size >= maxFileSize else { return }

        // Close current handle before renaming.
        fileHandle?.closeFile()
        fileHandle = nil

        let rotatedURL = fileURL.appendingPathExtension("1")
        try? fm.removeItem(at: rotatedURL)
        try? fm.moveItem(at: fileURL, to: rotatedURL)
    }

    deinit {
        fileHandle?.closeFile()
    }
}
