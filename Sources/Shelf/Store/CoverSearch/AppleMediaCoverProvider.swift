import Foundation

/// Supplemental cover provider querying the iTunes Search API for eBooks and movies.
struct AppleMediaCoverProvider: CoverSearchProvider {
    private struct SearchResponse: Decodable {
        struct Item: Decodable {
            let trackId: Int?
            let trackName: String?
            let artworkUrl100: String?
        }
        let results: [Item]?
    }

    func priority(for category: MediaCategory?) -> Int? {
        switch category {
        case .novel, .video: return 1
        case .game, nil: return nil
        }
    }

    func search(keyword: String, category: MediaCategory?, language: AppLanguage) async -> [CoverCandidate] {
        guard let spec = querySpec(for: category, language: language) else { return [] }
        let country = (language == .zh) ? "CN" : "US"
        guard let url = CoverHTTPClient.makeURL(
            "https://itunes.apple.com/search",
            queryItems: [
                URLQueryItem(name: "term", value: keyword),
                URLQueryItem(name: "country", value: country),
                URLQueryItem(name: "media", value: spec.media),
                URLQueryItem(name: "limit", value: "\(spec.limit)")
            ]
        ) else { return [] }

        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue(CoverHTTPClient.appUserAgent, forHTTPHeaderField: "User-Agent")

        guard let decoded = await CoverHTTPClient.fetchJSON(SearchResponse.self, request: req),
              let items = decoded.results else { return [] }

        return items.compactMap { item in
            guard let id = item.trackId,
                  let name = item.trackName,
                  let art100 = item.artworkUrl100 else {
                return nil
            }
            return CoverCandidate(
                id: "apple-\(spec.media)-\(id)",
                title: name,
                sourceTag: spec.sourceTag,
                previewURL: art100.replacingOccurrences(of: "100x100bb", with: "400x600bb"),
                fullURL: art100.replacingOccurrences(of: "100x100bb", with: "900x900bb")
            )
        }
    }

    private func querySpec(for category: MediaCategory?, language: AppLanguage) -> (media: String, sourceTag: String, limit: Int)? {
        switch category {
        case .novel:
            return ("ebook", language.tr("电子书封面", "eBook"), 8)
        case .video:
            return ("movie", language.tr("电影海报", "Movie"), 6)
        case .game, nil:
            return nil
        }
    }
}
