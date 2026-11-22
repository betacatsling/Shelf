import CoreGraphics
import Foundation

actor CoverSearchService {
    static let shared = CoverSearchService()

    private struct PreviewLoad {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<CGImage?, Never>]
    }

    private final class Preview: NSObject {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private let providers: [any CoverSearchProvider]
    private let previewCache = NSCache<NSString, Preview>()
    private var previewLoads: [String: PreviewLoad] = [:]
    private let previewSession: URLSession
    private let previewDecoder = DispatchQueue(label: "shelf.online-preview-decode", qos: .userInitiated)

    init(providers: [any CoverSearchProvider] = [
        SteamCoverProvider(),
        BangumiCoverProvider(),
        AppleMediaCoverProvider()
    ]) {
        self.providers = providers
        previewCache.countLimit = 100
        previewCache.totalCostLimit = 16 * 1024 * 1024
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 4
        config.urlCache = URLCache(memoryCapacity: 8 * 1024 * 1024, diskCapacity: 0)
        previewSession = URLSession(configuration: config)
    }

    func loadPreviewImage(from urlString: String) async -> CGImage? {
        if let cached = previewCache.object(forKey: urlString as NSString) { return cached.image }
        guard let url = URL(string: urlString), CoverHTTPClient.isHTTPURL(url), !Task.isCancelled else { return nil }

        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: nil)
                } else if previewLoads[urlString] != nil {
                    previewLoads[urlString]?.waiters[id] = continuation
                } else {
                    let generation = UUID()
                    let task = Task {
                        let image = await downloadPreview(url)
                        finishPreview(urlString, generation: generation, image: image)
                    }
                    previewLoads[urlString] = PreviewLoad(id: generation, task: task, waiters: [id: continuation])
                }
            }
        } onCancel: {
            Task { await self.cancelPreview(urlString, waiter: id) }
        }
    }

    private func cancelPreview(_ urlString: String, waiter id: UUID) {
        guard let waiter = previewLoads[urlString]?.waiters.removeValue(forKey: id) else { return }
        waiter.resume(returning: nil)
        if previewLoads[urlString]?.waiters.isEmpty == true {
            previewLoads.removeValue(forKey: urlString)?.task.cancel()
        }
    }

    private func finishPreview(_ urlString: String, generation: UUID, image: CGImage?) {
        guard let load = previewLoads[urlString], load.id == generation else { return }
        previewLoads.removeValue(forKey: urlString)
        if let image {
            previewCache.setObject(Preview(image), forKey: urlString as NSString, cost: image.bytesPerRow * image.height)
        }
        for waiter in load.waiters.values { waiter.resume(returning: image) }
    }

    private func downloadPreview(_ url: URL) async -> CGImage? {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue(CoverHTTPClient.browserUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await previewSession.data(for: request),
              let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode),
              !Task.isCancelled else { return nil }
        return await withCheckedContinuation { continuation in
            previewDecoder.async {
                continuation.resume(returning: CoverImageIO.decode(data: data, maxPixel: 340))
            }
        }
    }

    func searchCoversProgressively(
        query: String,
        category: MediaCategory?,
        language: AppLanguage = .zh,
        onBatch: @escaping @MainActor ([CoverCandidate]) -> Void
    ) async {
        let keyword = query.trimmed
        guard !keyword.isEmpty else {
            await onBatch([])
            return
        }

        let activeProviders = providers.compactMap { provider -> (priority: Int, provider: any CoverSearchProvider)? in
            guard let priority = provider.priority(for: category) else { return nil }
            return (priority, provider)
        }
        guard !activeProviders.isEmpty else {
            await onBatch([])
            return
        }

        await withTaskGroup(of: (Int, Int, [CoverCandidate]).self) { group in
            for (index, entry) in activeProviders.enumerated() {
                group.addTask {
                    let results = await entry.provider.search(keyword: keyword, category: category, language: language)
                    return (entry.priority, index, results)
                }
            }

            var buckets: [Int: (priority: Int, items: [CoverCandidate])] = [:]
            var lastBatch: [CoverCandidate]?
            for await (priority, index, list) in group {
                guard !Task.isCancelled else { return }
                buckets[index] = (priority, list)
                let ordered = buckets
                    .sorted { lhs, rhs in
                        if lhs.value.priority != rhs.value.priority { return lhs.value.priority < rhs.value.priority }
                        return lhs.key < rhs.key
                    }
                    .flatMap(\.value.items)
                let merged = deduplicate(ordered)
                if !merged.isEmpty, merged != lastBatch {
                    lastBatch = merged
                    await onBatch(merged)
                }
            }
            if !Task.isCancelled, lastBatch == nil { await onBatch([]) }
        }
    }

    private func deduplicate(_ list: [CoverCandidate]) -> [CoverCandidate] {
        var seenURLs = Set<String>()
        var output: [CoverCandidate] = []
        for item in list {
            if seenURLs.insert(item.fullURL).inserted {
                output.append(item)
            }
        }
        return output
    }
}
