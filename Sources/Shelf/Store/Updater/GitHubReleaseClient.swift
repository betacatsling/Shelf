import Foundation

struct GitHubRelease: Decodable, Equatable, Sendable {
    struct Asset: Decodable, Equatable, Sendable {
        let name: String
        let browser_download_url: String
        let size: Int?
        let digest: String?

        init(name: String, browser_download_url: String, size: Int? = nil, digest: String? = nil) {
            self.name = name
            self.browser_download_url = browser_download_url
            self.size = size
            self.digest = digest
        }
    }

    let tag_name: String
    let name: String?
    let body: String?
    let html_url: String
    let draft: Bool?
    let prerelease: Bool?
    let assets: [Asset]

    private enum CodingKeys: String, CodingKey {
        case tag_name, name, body, html_url, draft, prerelease, assets
    }

    init(
        tag_name: String,
        name: String? = nil,
        body: String? = nil,
        html_url: String,
        draft: Bool? = false,
        prerelease: Bool? = false,
        assets: [Asset] = []
    ) {
        self.tag_name = tag_name
        self.name = name
        self.body = body
        self.html_url = html_url
        self.draft = draft
        self.prerelease = prerelease
        self.assets = assets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tag_name = try container.decode(String.self, forKey: .tag_name)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        body = try container.decodeIfPresent(String.self, forKey: .body)
        html_url = try container.decode(String.self, forKey: .html_url)
        draft = try container.decodeIfPresent(Bool.self, forKey: .draft)
        prerelease = try container.decodeIfPresent(Bool.self, forKey: .prerelease)
        assets = try container.decodeIfPresent([Asset].self, forKey: .assets) ?? []
    }
}

struct ReleaseAsset: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case dmg
        case zip
    }

    let name: String
    let downloadURL: URL
    let size: Int?
    let sha256Hex: String?
    let kind: Kind

    static func parseSHA256Digest(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let normalized = raw.trimmed.lowercased()
        guard normalized.hasPrefix("sha256:") else { return nil }
        let hex = String(normalized.dropFirst("sha256:".count))
        guard hex.count == 64,
              hex.allSatisfy({ ($0 >= "0" && $0 <= "9") || ($0 >= "a" && $0 <= "f") })
        else {
            return nil
        }
        return hex
    }
}

struct AvailableUpdate: Equatable, Sendable {
    let version: AppVersion
    let displayTag: String
    let releasePageURL: URL
    let notes: String
    let asset: ReleaseAsset?
}

enum UpdaterError: Error, Equatable {
    case networkFailed
    case noReleasesFound
    case httpError(statusCode: Int, rateLimited: Bool)
    case invalidReleaseTag(String)
    case downloadFailed(statusCode: Int?)
    case checksumMismatch
    case mountFailed
    case missingAppBundle
    case invalidBundle
    case invalidSignature
    case installFailed

    func message(in lang: AppLanguage) -> String {
        switch self {
        case .networkFailed:
            return lang.tr("无法连接到 GitHub", "Could not connect to GitHub")
        case .noReleasesFound:
            return lang.tr("暂无可用发布版本", "No published releases found")
        case .httpError(let code, let rateLimited):
            if rateLimited {
                return lang.tr("GitHub API 请求频率受限，请稍后再试", "GitHub API rate limit reached; try again later")
            }
            return lang.tr("服务器返回异常状态 (\(code))", "Server returned status \(code)")
        case .invalidReleaseTag(let tag):
            return lang.tr("无法解析版本号：\(tag)", "Unrecognized release tag: \(tag)")
        case .downloadFailed(let code):
            if let code {
                return lang.tr("下载安装包失败 (\(code))", "Failed to download installer (\(code))")
            }
            return lang.tr("下载安装包失败", "Failed to download installer")
        case .checksumMismatch:
            return lang.tr("安装包完整性校验未通过", "Checksum verification failed")
        case .mountFailed:
            return lang.tr("无法挂载或读取下载的磁盘镜像", "Could not mount downloaded disk image")
        case .missingAppBundle:
            return lang.tr("安装包中未找到 Shelf.app", "Shelf.app was not found inside the installer")
        case .invalidBundle:
            return lang.tr("下载的应用包信息不完整", "Downloaded application bundle is invalid")
        case .invalidSignature:
            return lang.tr("新版本签名校验未通过", "Code signature verification failed")
        case .installFailed:
            return lang.tr("替换应用时出错", "Failed to replace the application")
        }
    }
}

enum GitHubReleaseClient {
    static let latestReleaseAPIURL = URL(string: "https://api.github.com/repos/betacatsling/Shelf/releases/latest")!
    static let releasesPageURL = URL(string: "https://github.com/betacatsling/Shelf/releases/latest")!

    private static let rejectedNameTokens = [
        "windows", "win-", "win64", "win32",
        "linux", "android",
        ".exe", ".msi", ".apk", ".rpm", ".deb", ".appimage",
        ".sha256", ".sha512", ".sig", ".asc", ".blockmap", ".json", ".txt"
    ]

    private static let apiSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    static func fetchLatestRelease(currentVersion: AppVersion) async throws -> GitHubRelease {
        var request = URLRequest(
            url: latestReleaseAPIURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15
        )
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Shelf-macOS/\(currentVersion.description)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await apiSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UpdaterError.networkFailed
        }
        if http.statusCode == 404 {
            throw UpdaterError.noReleasesFound
        }
        guard (200...299).contains(http.statusCode) else {
            let rateLimited = (http.statusCode == 403 || http.statusCode == 429)
                && http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0"
            throw UpdaterError.httpError(statusCode: http.statusCode, rateLimited: rateLimited)
        }
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    static func selectMacOSAsset(from assets: [GitHubRelease.Asset], arch: String) -> ReleaseAsset? {
        var best: (score: Int, asset: ReleaseAsset)?

        for raw in assets {
            guard let url = URL(string: raw.browser_download_url),
                  url.scheme?.lowercased() == "https"
            else {
                continue
            }

            let lower = raw.name.lowercased()
            if rejectedNameTokens.contains(where: { lower.contains($0) }) {
                continue
            }

            let kind: ReleaseAsset.Kind
            if lower.hasSuffix(".dmg") {
                kind = .dmg
            } else if lower.hasSuffix(".zip") && (
                lower.contains("mac")
                    || lower.contains("macos")
                    || lower.contains("darwin")
                    || lower.contains("osx")
                    || lower.hasSuffix(".app.zip")
            ) {
                kind = .zip
            } else {
                continue
            }

            let tokens = Set(lower.split { !$0.isLetter && !$0.isNumber }.map(String.init))
            let hasArm = tokens.contains("arm64") || tokens.contains("aarch64") || lower.contains("apple-silicon")
            let hasIntel = tokens.contains("x86") && tokens.contains("64")
                || lower.contains("x86_64")
                || tokens.contains("x64")
                || tokens.contains("amd64")
                || tokens.contains("intel")
            let isUniversal = tokens.contains("universal") || tokens.contains("all")

            let archScore: Int
            if arch == "arm64" {
                if hasIntel && !hasArm && !isUniversal { continue }
                archScore = hasArm ? 30 : (isUniversal ? 20 : 10)
            } else {
                if hasArm && !hasIntel && !isUniversal { continue }
                archScore = hasIntel ? 30 : (isUniversal ? 20 : 10)
            }

            let formatScore = (kind == .dmg) ? 100 : 50
            let totalScore = formatScore + archScore

            let candidate = ReleaseAsset(
                name: raw.name,
                downloadURL: url,
                size: raw.size,
                sha256Hex: ReleaseAsset.parseSHA256Digest(raw.digest),
                kind: kind
            )

            if let currentBest = best {
                if totalScore > currentBest.score {
                    best = (totalScore, candidate)
                }
            } else {
                best = (totalScore, candidate)
            }
        }

        return best?.asset
    }
}
