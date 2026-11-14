import Foundation

/// Serializes disk access to library.json. Every write replaces the complete file atomically.
final class LibraryFile: Sendable {
    let url: URL
    private let queue = DispatchQueue(label: "shelf.library-file", qos: .utility)

    init(url: URL) {
        self.url = url
    }

    func load() async throws -> [MediaItem]? {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [url] in
                continuation.resume(with: Result {
                    do {
                        return try Self.read(from: url)
                    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                        return nil
                    }
                })
            }
        }
    }

    func save(_ items: [MediaItem], completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void) {
        queue.async { [url] in
            let result = Result { try Self.write(items, to: url) }
            Task { @MainActor in completion(result) }
        }
    }

    /// A synchronous barrier for normal app termination, including any write already in progress.
    func flush(_ items: [MediaItem]) throws {
        try queue.sync {
            try Self.write(items, to: url)
        }
    }

    static func read(from url: URL) throws -> [MediaItem] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([MediaItem].self, from: Data(contentsOf: url))
    }

    static func write(_ items: [MediaItem], to url: URL, formatted: Bool = false) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if formatted {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        } else {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try encoder.encode(items).write(to: url, options: .atomic)
    }
}
