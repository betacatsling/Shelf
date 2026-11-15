import AppKit
import Foundation
import IOSurface
import UniformTypeIdentifiers

enum CoverSource: Sendable {
    case file(URL)
    case data(Data)
    case remote(String)
}

@MainActor
final class CoverManager {
    static let shared = CoverManager()

    enum Request: Hashable, Sendable {
        case thumbnail(String)
        case preview(String)
        case placeholder(PosterPlaceholder)

        var fileName: String? {
            switch self {
            case .thumbnail(let name), .preview(let name): return name
            case .placeholder: return nil
            }
        }
    }

    struct Artwork: @unchecked Sendable {
        // A surface is filled on a worker and then treated as immutable.
        let image: CGImage?
        let backdrop: CGImage?
        private let surface: IOSurfaceRef?

        var contents: Any? { surface.map { $0 as Any } ?? image }
        var bytes: Int {
            (image.map { $0.bytesPerRow * $0.height } ?? 0)
                + (backdrop.map { $0.bytesPerRow * $0.height } ?? 0)
                + (surface.map(IOSurfaceGetAllocSize) ?? 0)
        }

        fileprivate init(_ image: CGImage, forPosterWall: Bool) {
            let surface = forPosterWall ? CoverImageIO.displaySurface(image) : nil
            self.surface = surface
            self.image = surface == nil ? image : nil
            backdrop = forPosterWall ? nil : CoverImageIO.previewBackdrop(image)
        }
    }

    private struct Load {
        let generation: UInt64
        var running = false
        var waiters: [UUID: CheckedContinuation<Artwork?, Never>] = [:]
    }

    private struct CachedImage {
        let artwork: Artwork
        let cost: Int
        var lastUse: UInt64
    }

    private struct Decoded {
        let artwork: Artwork?
        var generatedThumbnail: Data?
    }

    private var images: [Request: CachedImage] = [:]
    private var imageBytes = 0
    private let maxImageBytes = 96 * 1024 * 1024
    private let maxEntries = 256
    private var missing: [Request: ContinuousClock.Instant] = [:]
    private var accessClock: UInt64 = 0
    private var loads: [Request: Load] = [:]
    private var prefetchPlans: [UUID: [Request]] = [:]
    private var generation: UInt64 = 0
    private var running = 0

    private let files = DispatchQueue(label: "shelf.cover-files", qos: .utility)
    private let encoders = DispatchQueue(label: "shelf.cover-imports", qos: .userInitiated)
    let coversDirectory: URL
    private let thumbnailsDirectory: URL

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let base = support.appendingPathComponent("Shelf", isDirectory: true)
        coversDirectory = base.appendingPathComponent("Covers", isDirectory: true)
        thumbnailsDirectory = base.appendingPathComponent("Thumbnails", isDirectory: true)
    }

    func cachedArtwork(for request: Request) -> Artwork? {
        guard var entry = images[request] else { return nil }
        accessClock &+= 1
        entry.lastUse = accessClock
        images[request] = entry
        return entry.artwork
    }

    func artwork(for request: Request) async -> Artwork? {
        if let hit = cachedArtwork(for: request) { return hit }
        guard !Task.isCancelled, canLoad(request) else { return nil }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: nil)
                    return
                }
                if loads[request] == nil { loads[request] = makeLoad() }
                loads[request]?.waiters[id] = continuation
                startAvailableLoads()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                loads[request]?.waiters.removeValue(forKey: id)?.resume(returning: nil)
                dropPendingLoadIfUnused(request)
            }
        }
    }

    func setPrefetchPlan(_ requests: [Request], for owner: UUID) {
        if requests.isEmpty {
            prefetchPlans.removeValue(forKey: owner)
        } else {
            prefetchPlans[owner] = requests
        }
        startAvailableLoads()
    }

    private func canLoad(_ request: Request) -> Bool {
        if let name = request.fileName, !Self.validFileName(name) { return false }
        if let expiry = missing[request] {
            guard expiry <= .now else { return false }
            missing.removeValue(forKey: request)
        }
        return true
    }

    private func makeLoad() -> Load {
        generation &+= 1
        return Load(generation: generation)
    }

    private func dropPendingLoadIfUnused(_ request: Request) {
        if let load = loads[request], !load.running, load.waiters.isEmpty {
            loads.removeValue(forKey: request)
        }
    }

    private func startAvailableLoads() {
        while running < 4 {
            // Leave capacity for the visible cards even during a fast scroll.
            let demand = loads.lazy.filter { !$0.value.running && !$0.value.waiters.isEmpty }
                .min { $0.value.generation < $1.value.generation }
            let request: Request
            let version: UInt64
            let qos: DispatchQoS.QoSClass
            if let (pending, load) = demand {
                request = pending
                version = load.generation
                qos = .userInitiated
            } else {
                guard running < 2, let next = nextPrefetch() else { return }
                request = next
                let load = makeLoad()
                loads[request] = load
                version = load.generation
                qos = .utility
            }
            loads[request]?.running = true
            running += 1
            let covers = coversDirectory
            let thumbnails = thumbnailsDirectory
            DispatchQueue.global(qos: qos).async { [weak self] in
                let decoded = Self.decode(request, covers: covers, thumbnails: thumbnails)
                Task { @MainActor [weak self] in self?.finish(request, generation: version, decoded: decoded) }
            }
        }
    }

    private func nextPrefetch() -> Request? {
        for plan in prefetchPlans.values {
            if let next = plan.first(where: { images[$0] == nil && loads[$0] == nil && canLoad($0) }) {
                return next
            }
        }
        return nil
    }

    private func finish(_ request: Request, generation: UInt64, decoded: Decoded) {
        running -= 1
        defer { startAvailableLoads() }
        guard let load = loads[request], load.generation == generation else { return }
        loads.removeValue(forKey: request)
        if let artwork = decoded.artwork {
            if !load.waiters.isEmpty || prefetchPlans.values.contains(where: { $0.contains(request) }) {
                insert(artwork, for: request)
            }
            if let data = decoded.generatedThumbnail, let fileName = request.fileName {
                let directory = thumbnailsDirectory
                files.async {
                    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try? data.write(to: directory.appendingPathComponent(fileName), options: .atomic)
                }
            }
        } else {
            markMissing(request)
        }
        for waiter in load.waiters.values { waiter.resume(returning: decoded.artwork) }
    }

    private func insert(_ artwork: Artwork, for request: Request) {
        removeCachedImage(for: request)
        missing.removeValue(forKey: request)
        accessClock &+= 1
        let cost = artwork.bytes
        images[request] = CachedImage(artwork: artwork, cost: cost, lastUse: accessClock)
        imageBytes += cost
        while imageBytes > maxImageBytes || images.count > maxEntries {
            guard let oldest = images.min(by: { lhs, rhs in
                return lhs.value.lastUse < rhs.value.lastUse
            })?.key else { break }
            removeCachedImage(for: oldest)
        }
    }

    private func removeCachedImage(for request: Request) {
        if let entry = images.removeValue(forKey: request) { imageBytes -= entry.cost }
    }

    private func markMissing(_ request: Request) {
        if missing.count >= 256 {
            missing = missing.filter { $0.value > .now }
            if missing.count >= 256, let oldest = missing.min(by: { $0.value < $1.value })?.key {
                missing.removeValue(forKey: oldest)
            }
        }
        missing[request] = .now + .seconds(20)
    }

    private nonisolated static func validFileName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }

    private nonisolated static func decode(_ request: Request, covers: URL, thumbnails: URL) -> Decoded {
        switch request {
        case .thumbnail(let name):
            let size = CoverImageIO.thumbnailPixels
            if let image = CoverImageIO.decode(file: thumbnails.appendingPathComponent(name), maxPixel: size) {
                return Decoded(artwork: Artwork(image, forPosterWall: true))
            }
            let image = CoverImageIO.decode(file: covers.appendingPathComponent(name), maxPixel: size)
            return Decoded(artwork: image.map { Artwork($0, forPosterWall: true) },
                           generatedThumbnail: image.flatMap { CoverImageIO.jpeg($0, quality: 0.85) })
        case .preview(let name):
            let image = CoverImageIO.decode(file: covers.appendingPathComponent(name), maxPixel: CoverImageIO.previewPixels)
                ?? CoverImageIO.decode(file: thumbnails.appendingPathComponent(name), maxPixel: CoverImageIO.thumbnailPixels)
            return Decoded(artwork: image.map { Artwork($0, forPosterWall: false) })
        case .placeholder(let placeholder):
            return Decoded(artwork: placeholder.draw().map { Artwork($0, forPosterWall: true) })
        }
    }

    // MARK: - Import & Removal

    func saveCover(from source: CoverSource) async throws -> String {
        let local: CoverSource
        switch source {
        case .remote(let url):
            local = .data(try await Self.downloadCover(url))
        case .file, .data:
            local = source
        }

        try Task.checkCancellation()
        let covers = coversDirectory
        let thumbnails = thumbnailsDirectory
        let name = "cover-\(UUID().uuidString).jpg"
        let images: (Artwork, Artwork?) = try await withCheckedThrowingContinuation { continuation in
            encoders.async {
                continuation.resume(with: Result {
                    try Self.writeImportedCover(local, name: name, covers: covers, thumbnails: thumbnails)
                })
            }
        }
        if Task.isCancelled {
            removeCover(fileName: name)
            throw CancellationError()
        }
        insert(images.0, for: .preview(name))
        if let thumbnail = images.1 { insert(thumbnail, for: .thumbnail(name)) }
        return name
    }

    private nonisolated static func writeImportedCover(
        _ source: CoverSource, name: String, covers: URL, thumbnails: URL
    ) throws -> (Artwork, Artwork?) {
        let decoded: CGImage?
        switch source {
        case .file(let url): decoded = CoverImageIO.decodeForImport(file: url)
        case .data(let data): decoded = CoverImageIO.decodeForImport(data: data)
        case .remote: throw CoverError.invalidURL
        }
        guard let decoded else { throw CoverError.invalidImageData }
        guard let jpeg = CoverImageIO.jpeg(decoded, quality: 0.88) else { throw CoverError.saveFailed }
        do {
            try FileManager.default.createDirectory(at: covers, withIntermediateDirectories: true)
            try jpeg.write(to: covers.appendingPathComponent(name), options: .atomic)
        } catch {
            throw CoverError.saveFailed
        }
        let thumbnail = CoverImageIO.resized(decoded, maxPixel: CoverImageIO.thumbnailPixels)
        if let thumbnail, let data = CoverImageIO.jpeg(thumbnail, quality: 0.85) {
            try? FileManager.default.createDirectory(at: thumbnails, withIntermediateDirectories: true)
            try? data.write(to: thumbnails.appendingPathComponent(name), options: .atomic)
        }
        let preview = CoverImageIO.resized(decoded, maxPixel: CoverImageIO.previewPixels) ?? decoded
        return (Artwork(preview, forPosterWall: false), thumbnail.map { Artwork($0, forPosterWall: true) })
    }

    private nonisolated static func downloadCover(_ urlString: String) async throws -> Data {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { throw CoverError.invalidURL }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw CoverError.downloadFailed
        }
        return data
    }

    func removeCover(fileName: String?) {
        guard let name = fileName, Self.validFileName(name) else { return }
        for request in [Request.thumbnail(name), .preview(name)] {
            removeCachedImage(for: request)
            markMissing(request)
            if let load = loads.removeValue(forKey: request) {
                for waiter in load.waiters.values { waiter.resume(returning: nil) }
            }
        }
        let file = coversDirectory.appendingPathComponent(name)
        let thumbnail = thumbnailsDirectory.appendingPathComponent(name)
        files.async {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: thumbnail)
        }
    }

    func chooseLocalImagePanel(lang: AppLanguage) -> URL? {
        let panel = NSOpenPanel()
        panel.title = lang.tr("选择海报封面图片", "Choose Cover Image")
        panel.prompt = lang.tr("设为封面", "Set Cover")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image, .jpeg, .png, .webP, .heic, .gif, .tiff]
        return panel.runModal() == .OK ? panel.url : nil
    }

    func inspectPasteboard(_ pasteboard: NSPasteboard = .general) -> CoverSource? {
        for type in [NSPasteboard.PasteboardType.png, .tiff, .pdf] {
            if let data = pasteboard.data(forType: type) { return .data(data) }
        }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let url = urls.first, let source = Self.source(for: url) {
            return source
        }
        if let value = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           let url = URL(string: value), let source = Self.source(for: url) {
            return source
        }
        if let data = NSImage(pasteboard: pasteboard)?.tiffRepresentation { return .data(data) }
        return nil
    }

    private nonisolated static func source(for url: URL) -> CoverSource? {
        if url.isFileURL { return .file(url) }
        if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            return .remote(url.absoluteString)
        }
        return nil
    }

    func readDroppedImage(
        from providers: [NSItemProvider], completion: @escaping @MainActor @Sendable (CoverSource?) -> Void
    ) -> Bool {
        guard let provider = providers.first else { return false }
        if let type = [UTType.fileURL, .url].first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) {
            provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { item, _ in
                let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                let source = url.flatMap(Self.source(for:))
                Task { @MainActor in completion(source) }
            }
            return true
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                Task { @MainActor in completion(data.map(CoverSource.data)) }
            }
            return true
        }
        return false
    }

}

enum CoverError: LocalizedError {
    case invalidURL
    case downloadFailed
    case invalidImageData
    case saveFailed

    func message(in lang: AppLanguage) -> String {
        switch self {
        case .invalidURL:
            return lang.tr("请输入有效的网络图片链接", "Please enter a valid image URL")
        case .downloadFailed:
            return lang.tr("无法下载该图片，请检查网络或尝试直接粘贴图片", "Failed to download image; please check the URL or paste directly")
        case .invalidImageData:
            return lang.tr("未能识别为有效图片格式", "Unrecognized image format")
        case .saveFailed:
            return lang.tr("保存封面图片失败", "Failed to save cover image")
        }
    }

    var errorDescription: String? {
        let raw = UserDefaults.standard.string(forKey: "shelf.language") ?? "zh"
        let lang = AppLanguage(rawValue: raw) ?? .zh
        return message(in: lang)
    }
}
