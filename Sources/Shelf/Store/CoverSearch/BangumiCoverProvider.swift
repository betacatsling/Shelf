import Foundation

/// Searches Bangumi subjects for games, books/novels, anime, and live-action video covers.
struct BangumiCoverProvider: CoverSearchProvider {
    private struct SearchRequest: Encodable {
        struct Filter: Encodable { let type: [Int] }
        let keyword: String
        let filter: Filter
    }

    private struct SearchResponse: Decodable {
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

    func priority(for category: MediaCategory?) -> Int? {
        switch category {
        case .novel, .video: return 0
        case .game, nil: return 1
        }
    }

    func search(keyword: String, category: MediaCategory?, language: AppLanguage) async -> [CoverCandidate] {
        let spec = querySpec(for: category, language: language)
        guard let url = CoverHTTPClient.makeURL(
            "https://api.bgm.tv/v0/search/subjects",
            queryItems: [URLQueryItem(name: "limit", value: "\(spec.limit)")]
        ) else { return [] }

        var req = URLRequest(url: url, timeoutInterval: 9)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("\(CoverHTTPClient.appUserAgent) (macOS)", forHTTPHeaderField: "User-Agent")

        let payload = SearchRequest(keyword: keyword, filter: .init(type: spec.types))
        guard let body = try? JSONEncoder().encode(payload) else { return [] }
        req.httpBody = body

        guard let decoded = await CoverHTTPClient.fetchJSON(SearchResponse.self, request: req),
              let subjects = decoded.data else { return [] }

        return subjects.compactMap { sub in
            let large = sub.images?.large ?? ""
            guard !large.isEmpty, let fullURL = URL(string: large), CoverHTTPClient.isHTTPURL(fullURL) else {
                return nil
            }
            let preview = sub.images?.common ?? sub.images?.medium ?? large
            let cn = (sub.name_cn ?? "").trimmed
            let displayTitle: String = (language == .zh)
                ? (cn.isEmpty ? sub.name : cn)
                : (sub.name.isEmpty ? cn : sub.name)
            return CoverCandidate(
                id: "bgm-\(sub.id)",
                title: displayTitle,
                sourceTag: spec.sourceTag,
                previewURL: preview.isEmpty ? large : preview,
                fullURL: large
            )
        }
    }

    private func querySpec(for category: MediaCategory?, language: AppLanguage) -> (types: [Int], sourceTag: String, limit: Int) {
        switch category {
        case .game:
            return ([4], language.tr("游戏封面", "Game Cover"), 12)
        case .novel:
            return ([1], language.tr("图书封面", "Book Cover"), 14)
        case .video:
            return ([2, 6], language.tr("影视海报", "Poster"), 16)
        case nil:
            return ([1, 2, 4, 6], language.tr("作品封面", "Cover"), 14)
        }
    }
}
