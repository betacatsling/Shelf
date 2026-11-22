import Foundation

struct CoverCandidate: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let sourceTag: String
    let previewURL: String
    let fullURL: String
}

/// Extensible plugin boundary for online cover artwork providers.
protocol CoverSearchProvider: Sendable {
    /// Returns the display priority bucket (lower appears earlier) if this provider supports `category`, or `nil` to skip.
    func priority(for category: MediaCategory?) -> Int?
    func search(keyword: String, category: MediaCategory?, language: AppLanguage) async -> [CoverCandidate]
}

enum CoverHTTPClient {
    static let appUserAgent = "Shelf-macOS/1.2"
    static let browserUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 Safari/605.1.15"

    static func isHTTPURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    static func makeURL(_ base: String, queryItems: [URLQueryItem]) -> URL? {
        guard var components = URLComponents(string: base) else { return nil }
        components.queryItems = queryItems
        return components.url
    }

    static func fetchJSON<T: Decodable>(
        _ type: T.Type,
        request: URLRequest,
        session: URLSession = .shared
    ) async -> T? {
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              !Task.isCancelled else {
            return nil
        }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
