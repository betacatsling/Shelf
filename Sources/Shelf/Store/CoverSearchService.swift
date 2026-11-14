import AppKit
import Foundation

struct CoverCandidate: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let sourceTag: String
    let previewURL: String
    let fullURL: String
}

actor CoverSearchService {
    static let shared = CoverSearchService()

    private let previewCache = NSCache<NSString, NSImage>()

    private init() {
        previewCache.countLimit = 120
    }

    func cachedPreview(for urlString: String) -> NSImage? {
        previewCache.object(forKey: urlString as NSString)
    }

    func loadPreviewImage(from urlString: String) async -> NSImage? {
        if let cached = previewCache.object(forKey: urlString as NSString) {
            return cached
        }
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return nil
            }
            guard let image = NSImage(data: data) else { return nil }
            previewCache.setObject(image, forKey: urlString as NSString)
            return image
        } catch {
            return nil
        }
    }

    func searchCoversProgressively(
        query: String,
        category: MediaCategory?,
        language: AppLanguage = .zh,
        onBatch: @escaping @MainActor ([CoverCandidate]) -> Void
    ) async {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else {
            await onBatch([])
            return
        }

        await withTaskGroup(of: (Int, [CoverCandidate]).self) { group in
            switch category {
            case .game:
                group.addTask {
                    (0, await self.searchSteamVerticalPosters(keyword: keyword, language: language, maxCount: 6))
                }
                group.addTask {
                    (1, await self.searchBangumi(keyword: keyword, types: [4], sourceTag: language.tr("游戏封面", "Game Cover"), language: language, limit: 12))
                }

            case .novel:
                group.addTask {
                    (0, await self.searchBangumi(keyword: keyword, types: [1], sourceTag: language.tr("图书封面", "Book Cover"), language: language, limit: 14))
                }
                group.addTask {
                    (1, await self.searchAppleMedia(keyword: keyword, media: "ebook", sourceTag: language.tr("电子书封面", "eBook"), language: language, limit: 8))
                }

            case .video:
                group.addTask {
                    (0, await self.searchBangumi(keyword: keyword, types: [2, 6], sourceTag: language.tr("影视海报", "Poster"), language: language, limit: 16))
                }
                group.addTask {
                    (1, await self.searchAppleMedia(keyword: keyword, media: "movie", sourceTag: language.tr("电影海报", "Movie"), language: language, limit: 6))
                }

            case nil:
                group.addTask {
                    (0, await self.searchSteamVerticalPosters(keyword: keyword, language: language, maxCount: 5))
                }
                group.addTask {
                    (1, await self.searchBangumi(keyword: keyword, types: [1, 2, 4, 6], sourceTag: language.tr("作品封面", "Cover"), language: language, limit: 14))
                }
            }

            var buckets: [Int: [CoverCandidate]] = [:]
            for await (priority, list) in group {
                guard !Task.isCancelled else { return }
                buckets[priority] = list
                let ordered = buckets.keys.sorted().flatMap { buckets[$0] ?? [] }
                let merged = deduplicate(ordered)
                if !merged.isEmpty {
                    await onBatch(merged)
                }
            }

            let finalOrdered = buckets.keys.sorted().flatMap { buckets[$0] ?? [] }
            await onBatch(deduplicate(finalOrdered))
        }
    }

    // MARK: - Steam Official 600x900 Vertical Library Posters

    private struct SteamSearchResponse: Decodable {
        struct Item: Decodable {
            let id: Int
            let name: String
        }
        let items: [Item]?
    }

    private struct SteamBrowseResponse: Decodable {
        struct Assets: Decodable {
            let asset_url_format: String?
            let library_capsule: String?
            let library_capsule_2x: String?
        }
        struct StoreItem: Decodable {
            let appid: Int?
            let name: String?
            let assets: Assets?
        }
        struct ResponseBody: Decodable {
            let store_items: [StoreItem]?
        }
        let response: ResponseBody?
    }

    private func searchSteamVerticalPosters(keyword: String, language: AppLanguage, maxCount: Int = 8) async -> [CoverCandidate] {
        let steamLang = (language == .zh) ? "schinese" : "english"
        let steamCC = (language == .zh) ? "CN" : "US"
        guard let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://store.steampowered.com/api/storesearch/?term=\(encoded)&l=\(steamLang)&cc=\(steamCC)")
        else {
            return []
        }

        var req = URLRequest(url: url)
        req.timeoutInterval = 7
        req.setValue("ShelfMacApp/1.0", forHTTPHeaderField: "User-Agent")

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(SteamSearchResponse.self, from: data),
              let rawItems = decoded.items,
              !rawItems.isEmpty
        else {
            return []
        }

        let topItems = Array(rawItems.prefix(maxCount))
        let idsJSON = topItems.map { "{\"appid\":\($0.id)}" }.joined(separator: ",")
        let inputJSON = "{\"ids\":[\(idsJSON)],\"context\":{\"language\":\"\(steamLang)\",\"country_code\":\"\(steamCC)\"},\"data_request\":{\"include_assets\":true}}"

        guard let browseEncoded = inputJSON.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let browseURL = URL(string: "https://api.steampowered.com/IStoreBrowseService/GetItems/v1/?input_json=\(browseEncoded)")
        else {
            return []
        }

        var browseReq = URLRequest(url: browseURL)
        browseReq.timeoutInterval = 7
        browseReq.setValue("ShelfMacApp/1.0", forHTTPHeaderField: "User-Agent")

        guard let (bData, bResp) = try? await URLSession.shared.data(for: browseReq),
              let bHttp = bResp as? HTTPURLResponse,
              (200...299).contains(bHttp.statusCode),
              let bDecoded = try? JSONDecoder().decode(SteamBrowseResponse.self, from: bData),
              let storeItems = bDecoded.response?.store_items
        else {
            return []
        }

        let nameFallback = Dictionary(uniqueKeysWithValues: topItems.map { ($0.id, $0.name) })
        var results: [CoverCandidate] = []
        for si in storeItems {
            guard let appid = si.appid,
                  let fmt = si.assets?.asset_url_format,
                  !fmt.isEmpty
            else { continue }

            let previewFile = si.assets?.library_capsule ?? si.assets?.library_capsule_2x
            let fullFile = si.assets?.library_capsule_2x ?? si.assets?.library_capsule
            guard let pFile = previewFile, let fFile = fullFile else { continue }

            let basePrefix = "https://shared.akamai.steamstatic.com/store_item_assets/"
            let previewURL = basePrefix + fmt.replacingOccurrences(of: "${FILENAME}", with: pFile)
            let fullURL = basePrefix + fmt.replacingOccurrences(of: "${FILENAME}", with: fFile)
            let title = si.name ?? nameFallback[appid] ?? language.tr("游戏封面", "Game Cover")

            results.append(
                CoverCandidate(
                    id: "steam-\(appid)",
                    title: title,
                    sourceTag: language.tr("官方竖版海报", "Official Poster"),
                    previewURL: previewURL,
                    fullURL: fullURL
                )
            )
        }
        return results
    }

    // MARK: - Bangumi Subject Search (Games, Books/Novels, Anime & Live-Action)

    private struct BangumiSearchRequest: Encodable {
        struct Filter: Encodable {
            let type: [Int]
        }
        let keyword: String
        let filter: Filter
    }

    private struct BangumiSearchResponse: Decodable {
        struct Images: Decodable {
            let large: String?
            let common: String?
            let medium: String?
        }
        struct Subject: Decodable {
            let id: Int
            let name: String
            let name_cn: String?
            let images: Images?
        }
        let data: [Subject]?
    }

    private func searchBangumi(keyword: String, types: [Int], sourceTag: String, language: AppLanguage, limit: Int) async -> [CoverCandidate] {
        guard let url = URL(string: "https://api.bgm.tv/v0/search/subjects?limit=\(limit)") else {
            return []
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 9
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("ShelfMacApp/1.0 (macOS)", forHTTPHeaderField: "User-Agent")

        let payload = BangumiSearchRequest(keyword: keyword, filter: .init(type: types))
        guard let body = try? JSONEncoder().encode(payload) else { return [] }
        req.httpBody = body

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(BangumiSearchResponse.self, from: data),
              let subjects = decoded.data
        else {
            return []
        }

        var results: [CoverCandidate] = []
        for sub in subjects {
            let large = sub.images?.large ?? ""
            let preview = sub.images?.common ?? sub.images?.medium ?? large
            guard !large.isEmpty, large.hasPrefix("http") else { continue }
            let cn = (sub.name_cn ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let displayTitle: String
            if language == .zh {
                displayTitle = cn.isEmpty ? sub.name : cn
            } else {
                displayTitle = sub.name.isEmpty ? cn : sub.name
            }
            results.append(
                CoverCandidate(
                    id: "bgm-\(sub.id)",
                    title: displayTitle,
                    sourceTag: sourceTag,
                    previewURL: preview.isEmpty ? large : preview,
                    fullURL: large
                )
            )
        }
        return results
    }

    // MARK: - Apple Books / Movies Supplement

    private struct AppleSearchResponse: Decodable {
        struct Item: Decodable {
            let trackId: Int?
            let trackName: String?
            let artworkUrl100: String?
        }
        let results: [Item]?
    }

    private func searchAppleMedia(keyword: String, media: String, sourceTag: String, language: AppLanguage, limit: Int) async -> [CoverCandidate] {
        let country = (language == .zh) ? "CN" : "US"
        guard let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://itunes.apple.com/search?term=\(encoded)&country=\(country)&media=\(media)&limit=\(limit)")
        else {
            return []
        }

        var req = URLRequest(url: url)
        req.timeoutInterval = 8

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(AppleSearchResponse.self, from: data),
              let items = decoded.results
        else {
            return []
        }

        return items.compactMap { item in
            guard let id = item.trackId,
                  let name = item.trackName,
                  let art100 = item.artworkUrl100
            else {
                return nil
            }
            let preview = art100.replacingOccurrences(of: "100x100bb", with: "400x600bb")
            let full = art100.replacingOccurrences(of: "100x100bb", with: "900x900bb")
            return CoverCandidate(
                id: "apple-\(media)-\(id)",
                title: name,
                sourceTag: sourceTag,
                previewURL: preview,
                fullURL: full
            )
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
