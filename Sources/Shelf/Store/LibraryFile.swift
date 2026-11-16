import Foundation

/// Serializes disk access to library.json and tags.json. Every write replaces the complete file atomically.
final class LibraryFile: Sendable {
    struct Snapshot: Sendable {
        let items: [MediaItem]?
        let tagCategories: [String]?
        let tagNodes: [TagNode]?
    }

    let url: URL
    var tagsURL: URL { url.deletingLastPathComponent().appendingPathComponent("tags.json") }
    private let queue = DispatchQueue(label: "shelf.library-file", qos: .utility)

    init(url: URL) {
        self.url = url
    }

    func loadSnapshot() async throws -> Snapshot {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [url, tagsURL] in
                continuation.resume(with: Result {
                    let items: [MediaItem]?
                    do {
                        items = try Self.read(from: url)
                    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                        items = nil
                    }
                    let catalog = try? Self.readTagCatalog(from: tagsURL)
                    return Snapshot(items: items, tagCategories: catalog?.categories, tagNodes: catalog?.nodes)
                })
            }
        }
    }

    func save(_ items: [MediaItem], tagCategories: [String], tagNodes: [TagNode], completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void) {
        queue.async { [url, tagsURL] in
            let result = Result {
                try Self.write(items, to: url)
                try Self.writeTagCatalog(categories: tagCategories, nodes: tagNodes, to: tagsURL)
            }
            Task { @MainActor in completion(result) }
        }
    }

    /// A synchronous barrier for normal app termination, including any write already in progress.
    func flush(_ items: [MediaItem], tagCategories: [String], tagNodes: [TagNode]) throws {
        try queue.sync {
            try Self.write(items, to: url)
            try Self.writeTagCatalog(categories: tagCategories, nodes: tagNodes, to: tagsURL)
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

    static func readTagCatalog(from url: URL) throws -> (categories: [String], nodes: [TagNode]) {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        if let payload = try? decoder.decode(TagCatalogPayload.self, from: data) {
            return TagCatalog.migrateV2PayloadIfNeeded(payload)
        }
        let flat = try decoder.decode([String].self, from: data)
        return TagCatalog.migrateLegacyTags(flat)
    }

    static func writeTagCatalog(categories: [String], nodes: [TagNode], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let payload = TagCatalogPayload(version: 3, categories: categories, nodes: nodes)
        try encoder.encode(payload).write(to: url, options: .atomic)
    }
}
