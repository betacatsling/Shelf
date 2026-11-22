import Foundation

/// Fetches official 600x900 vertical Steam library posters via Steam Store Search + IStoreBrowseService.
struct SteamCoverProvider: CoverSearchProvider {
    private struct SearchResponse: Decodable {
        struct Item: Decodable {
            let id: Int
            let name: String
        }
        let items: [Item]?
    }

    private struct BrowseInput: Encodable {
        struct AppID: Encodable { let appid: Int }
        struct Context: Encodable {
            let language: String
            let country_code: String
        }
        struct DataRequest: Encodable {
            let include_assets: Bool
        }
        let ids: [AppID]
        let context: Context
        let data_request: DataRequest
    }

    private struct BrowseResponse: Decodable {
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

    func priority(for category: MediaCategory?) -> Int? {
        switch category {
        case .game, nil: return 0
        case .novel, .video: return nil
        }
    }

    func search(keyword: String, category: MediaCategory?, language: AppLanguage) async -> [CoverCandidate] {
        let maxCount = (category == nil) ? 5 : 6
        let steamLang = (language == .zh) ? "schinese" : "english"
        let steamCC = (language == .zh) ? "CN" : "US"

        guard let searchURL = CoverHTTPClient.makeURL(
            "https://store.steampowered.com/api/storesearch/",
            queryItems: [
                URLQueryItem(name: "term", value: keyword),
                URLQueryItem(name: "l", value: steamLang),
                URLQueryItem(name: "cc", value: steamCC)
            ]
        ) else { return [] }

        var req = URLRequest(url: searchURL, timeoutInterval: 7)
        req.setValue(CoverHTTPClient.appUserAgent, forHTTPHeaderField: "User-Agent")

        guard let decoded = await CoverHTTPClient.fetchJSON(SearchResponse.self, request: req),
              let rawItems = decoded.items,
              !rawItems.isEmpty else { return [] }

        let topItems = Array(rawItems.prefix(maxCount))
        let browseInput = BrowseInput(
            ids: topItems.map { .init(appid: $0.id) },
            context: .init(language: steamLang, country_code: steamCC),
            data_request: .init(include_assets: true)
        )
        guard let inputData = try? JSONEncoder().encode(browseInput),
              let inputJSON = String(data: inputData, encoding: .utf8),
              let browseURL = CoverHTTPClient.makeURL(
                "https://api.steampowered.com/IStoreBrowseService/GetItems/v1/",
                queryItems: [URLQueryItem(name: "input_json", value: inputJSON)]
              ) else { return [] }

        var browseReq = URLRequest(url: browseURL, timeoutInterval: 7)
        browseReq.setValue(CoverHTTPClient.appUserAgent, forHTTPHeaderField: "User-Agent")

        guard let browseDecoded = await CoverHTTPClient.fetchJSON(BrowseResponse.self, request: browseReq),
              let storeItems = browseDecoded.response?.store_items else { return [] }

        let nameFallback = Dictionary(topItems.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let basePrefix = "https://shared.akamai.steamstatic.com/store_item_assets/"
        return storeItems.compactMap { si in
            guard let appid = si.appid,
                  let fmt = si.assets?.asset_url_format, !fmt.isEmpty,
                  let previewFile = si.assets?.library_capsule ?? si.assets?.library_capsule_2x,
                  let fullFile = si.assets?.library_capsule_2x ?? si.assets?.library_capsule else {
                return nil
            }
            return CoverCandidate(
                id: "steam-\(appid)",
                title: si.name ?? nameFallback[appid] ?? language.tr("游戏封面", "Game Cover"),
                sourceTag: language.tr("官方竖版海报", "Official Poster"),
                previewURL: basePrefix + fmt.replacingOccurrences(of: "${FILENAME}", with: previewFile),
                fullURL: basePrefix + fmt.replacingOccurrences(of: "${FILENAME}", with: fullFile)
            )
        }
    }
}
