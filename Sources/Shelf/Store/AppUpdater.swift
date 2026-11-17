import AppKit
import CryptoKit
import Foundation
import Observation

struct AppVersion: Comparable, Equatable, Hashable, CustomStringConvertible, Sendable {
    static let fallbackCurrent = "1.2.5"

    let components: [Int]
    let prerelease: String?
    let rawCoreString: String

    private var normalizedComponents: [Int] {
        var trimmed = components
        while trimmed.count > 1, trimmed.last == 0 {
            trimmed.removeLast()
        }
        return trimmed
    }

    init?(parsing raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("v") || text.hasPrefix("V") {
            text.removeFirst()
        }
        if let plusIndex = text.firstIndex(of: "+") {
            text = String(text[..<plusIndex])
        }

        let coreString: String
        let prereleasePart: String?
        if let dashIndex = text.firstIndex(of: "-") {
            coreString = String(text[..<dashIndex])
            let suffix = String(text[text.index(after: dashIndex)...])
            guard !suffix.isEmpty else { return nil }
            prereleasePart = suffix
        } else {
            coreString = text
            prereleasePart = nil
        }

        let parts = coreString.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }

        var parsed: [Int] = []
        parsed.reserveCapacity(parts.count)
        for part in parts {
            guard !part.isEmpty,
                  part.allSatisfy({ $0 >= "0" && $0 <= "9" }),
                  let number = Int(part)
            else {
                return nil
            }
            parsed.append(number)
        }

        self.components = parsed
        self.prerelease = prereleasePart
        self.rawCoreString = coreString
    }

    var description: String {
        if let prerelease {
            return "\(rawCoreString)-\(prerelease)"
        }
        return rawCoreString
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        lhs.normalizedComponents == rhs.normalizedComponents && lhs.prerelease == rhs.prerelease
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(normalizedComponents)
        hasher.combine(prerelease)
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let l = index < lhs.components.count ? lhs.components[index] : 0
            let r = index < rhs.components.count ? rhs.components[index] : 0
            if l != r {
                return l < r
            }
        }

        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil):
            return false
        case (nil, .some):
            return false
        case (.some, nil):
            return true
        case (.some(let l), .some(let r)):
            return comparePrerelease(l, r)
        }
    }

    private static func comparePrerelease(_ lhs: String, _ rhs: String) -> Bool {
        let leftParts = lhs.split(separator: ".", omittingEmptySubsequences: false)
        let rightParts = rhs.split(separator: ".", omittingEmptySubsequences: false)
        let count = min(leftParts.count, rightParts.count)

        for index in 0..<count {
            let l = leftParts[index]
            let r = rightParts[index]
            if l == r { continue }

            let lInt = l.allSatisfy({ $0 >= "0" && $0 <= "9" }) ? Int(l) : nil
            let rInt = r.allSatisfy({ $0 >= "0" && $0 <= "9" }) ? Int(r) : nil

            switch (lInt, rInt) {
            case (.some(let li), .some(let ri)):
                return li < ri
            case (.some, nil):
                return true
            case (nil, .some):
                return false
            case (nil, nil):
                return l.compare(r, options: .literal) == .orderedAscending
            }
        }

        return leftParts.count < rightParts.count
    }
}

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
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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

@MainActor
@Observable
final class AppUpdater {
    enum Phase: Equatable {
        case idle
        case checking
        case available(AvailableUpdate)
        case downloading(AvailableUpdate, progress: Double?)
        case installing(AvailableUpdate)
        case failed(AvailableUpdate, message: String)
    }

    typealias ReleaseFetcher = @Sendable () async throws -> GitHubRelease
    typealias AssetDownloader = @Sendable (URL, URL, @escaping @MainActor @Sendable (Double?) -> Void) async throws -> Void
    typealias URLOpener = @MainActor (URL) -> Void
    typealias AppTerminator = @MainActor () -> Void

    nonisolated static let latestReleaseAPIURL = URL(string: "https://api.github.com/repos/betacatsling/Shelf/releases/latest")!
    nonisolated static let releasesPageURL = URL(string: "https://github.com/betacatsling/Shelf/releases/latest")!

    #if arch(arm64)
    nonisolated static let currentArch = "arm64"
    #elseif arch(x86_64)
    nonisolated static let currentArch = "x86_64"
    #else
    nonisolated static let currentArch = "arm64"
    #endif

    private nonisolated static let rejectedNameTokens = [
        "windows", "win-", "win64", "win32",
        "linux", "android",
        ".exe", ".msi", ".apk", ".rpm", ".deb", ".appimage",
        ".sha256", ".sha512", ".sig", ".asc", ".blockmap", ".json", ".txt"
    ]

    private nonisolated static let apiSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    private(set) var phase: Phase = .idle
    let currentVersion: AppVersion
    let bundleURL: URL
    let expectedBundleIdentifier: String

    var onToast: ((String) -> Void)?
    var languageProvider: () -> AppLanguage = { .zh }
    var flushBeforeQuit: (() throws -> Void)?

    @ObservationIgnored private let releaseFetcher: ReleaseFetcher
    @ObservationIgnored private let assetDownloader: AssetDownloader
    @ObservationIgnored private let openURL: URLOpener
    @ObservationIgnored private let terminateApp: AppTerminator
    @ObservationIgnored private let downloadsDirectory: URL

    @ObservationIgnored private var hasStartedAutomaticChecks = false
    @ObservationIgnored private var isChecking = false
    @ObservationIgnored private var lastCheckedAt: Date?
    @ObservationIgnored private var periodicCheckTask: Task<Void, Never>?
    @ObservationIgnored private var activeUpdateTask: Task<Void, Never>?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?

    init(
        currentVersionString: String? = nil,
        bundleURL: URL = Bundle.main.bundleURL,
        expectedBundleIdentifier: String? = Bundle.main.bundleIdentifier,
        downloadsDirectory: URL? = nil,
        releaseFetcher: ReleaseFetcher? = nil,
        assetDownloader: AssetDownloader? = nil,
        openURL: URLOpener? = nil,
        terminateApp: AppTerminator? = nil
    ) {
        let versionString = currentVersionString
            ?? ProcessInfo.processInfo.environment["SHELF_CURRENT_VERSION_OVERRIDE"]
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? AppVersion.fallbackCurrent
        let resolvedVersion = AppVersion(parsing: versionString)
            ?? AppVersion(parsing: AppVersion.fallbackCurrent)!
        self.currentVersion = resolvedVersion
        self.bundleURL = bundleURL
        self.expectedBundleIdentifier = expectedBundleIdentifier ?? "com.local.shelf.mediatracker"
        self.downloadsDirectory = downloadsDirectory
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
        self.releaseFetcher = releaseFetcher ?? {
            try await Self.defaultFetchLatestRelease(currentVersion: resolvedVersion)
        }
        self.assetDownloader = assetDownloader ?? { url, destinationURL, onProgress in
            try await ReleaseDownloadDelegate.download(
                from: url,
                to: destinationURL,
                userAgent: "Shelf-macOS/\(resolvedVersion.description)",
                onProgress: onProgress
            )
        }
        self.openURL = openURL ?? { url in
            NSWorkspace.shared.open(url)
        }
        self.terminateApp = terminateApp ?? {
            NSApplication.shared.terminate(nil)
        }
    }

    var availableUpdate: AvailableUpdate? {
        switch phase {
        case .available(let update),
             .downloading(let update, _),
             .installing(let update),
             .failed(let update, _):
            return update
        case .idle, .checking:
            return nil
        }
    }

    var isBusy: Bool {
        if isChecking { return true }
        switch phase {
        case .checking, .downloading, .installing:
            return true
        case .idle, .available, .failed:
            return false
        }
    }

    func startAutomaticChecksIfNeeded() {
        guard !hasStartedAutomaticChecks else { return }
        hasStartedAutomaticChecks = true

        periodicCheckTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            while !Task.isCancelled {
                guard let self else { break }
                await self.checkForUpdatesNow(userInitiated: false)
                try? await Task.sleep(for: .seconds(6 * 3600))
            }
        }

        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      let lastCheckedAt = self.lastCheckedAt,
                      Date().timeIntervalSince(lastCheckedAt) >= 4 * 3600,
                      !self.isBusy
                else {
                    return
                }
                await self.checkForUpdatesNow(userInitiated: false)
            }
        }
    }

    func checkForUpdates(userInitiated: Bool) {
        Task { [weak self] in
            await self?.checkForUpdatesNow(userInitiated: userInitiated)
        }
    }

    @discardableResult
    func checkForUpdatesNow(userInitiated: Bool) async -> Phase {
        guard !isBusy else { return phase }

        let lang = languageProvider()
        let previousAvailable = availableUpdate
        isChecking = true
        lastCheckedAt = Date()
        if case .idle = phase {
            phase = .checking
        }
        defer { isChecking = false }

        do {
            let release = try await releaseFetcher()
            if release.draft == true || release.prerelease == true {
                phase = .idle
                if userInitiated {
                    onToast?(upToDateToast(in: lang))
                }
                return phase
            }

            guard let remoteVersion = AppVersion(parsing: release.tag_name) else {
                throw UpdaterError.invalidReleaseTag(release.tag_name)
            }

            if remoteVersion > currentVersion {
                let pageURL = URL(string: release.html_url) ?? Self.releasesPageURL
                let update = AvailableUpdate(
                    version: remoteVersion,
                    displayTag: "v\(remoteVersion.description)",
                    releasePageURL: pageURL,
                    notes: release.body ?? "",
                    asset: Self.selectMacOSAsset(from: release.assets)
                )
                phase = .available(update)
                if userInitiated {
                    onToast?(lang.tr(
                        "发现新版本 \(update.displayTag)，可点击左下角按钮更新",
                        "New version \(update.displayTag) available in the bottom-left"
                    ))
                }
            } else {
                phase = .idle
                if userInitiated {
                    onToast?(upToDateToast(in: lang))
                }
            }
        } catch UpdaterError.noReleasesFound {
            phase = .idle
            if userInitiated {
                onToast?(upToDateToast(in: lang))
            }
        } catch {
            if let previousAvailable {
                phase = .available(previousAvailable)
            } else {
                phase = .idle
            }
            if userInitiated {
                let msg = Self.localizedErrorMessage(error, lang: lang)
                onToast?(lang.tr("检查更新失败：\(msg)", "Update check failed: \(msg)"))
            }
        }

        return phase
    }

    func performUpdate() {
        guard activeUpdateTask == nil else { return }
        activeUpdateTask = Task { [weak self] in
            await self?.performUpdateNow()
        }
    }

    func cancelDownload() {
        activeUpdateTask?.cancel()
    }

    @discardableResult
    func performUpdateNow() async -> Phase {
        let update: AvailableUpdate
        switch phase {
        case .available(let candidate), .failed(let candidate, _):
            update = candidate
        case .idle, .checking, .downloading, .installing:
            return phase
        }

        defer { activeUpdateTask = nil }

        guard let asset = update.asset else {
            openURL(update.releasePageURL)
            return phase
        }

        let lang = languageProvider()
        phase = .downloading(update, progress: 0)

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShelfUpdate-\(UUID().uuidString)", isDirectory: true)
        var keepWorkDirForHelper = false

        defer {
            if !keepWorkDirForHelper {
                try? FileManager.default.removeItem(at: workDir)
            }
        }

        do {
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            let safeName = Self.sanitizedArchiveName(asset.name)
            let archiveURL = workDir.appendingPathComponent(safeName)

            try await assetDownloader(asset.downloadURL, archiveURL) { [weak self] progress in
                guard let self, case .downloading(let current, _) = self.phase else { return }
                self.phase = .downloading(current, progress: progress)
            }

            try Task.checkCancellation()

            if let expectedHex = asset.sha256Hex {
                let matches = try await Task.detached(priority: .utility) {
                    try Self.verifySHA256(fileURL: archiveURL, expectedHex: expectedHex)
                }.value
                guard matches else {
                    throw UpdaterError.checksumMismatch
                }
            }

            try Task.checkCancellation()
            phase = .installing(update)

            guard Self.canReplaceInPlace(bundleURL: bundleURL) else {
                let destination = downloadsDirectory.appendingPathComponent(safeName)
                try FileManager.default.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: archiveURL, to: destination)

                phase = .available(update)
                openURL(destination)
                onToast?(lang.tr(
                    "已下载并打开安装包，请拖入「应用程序」完成更新",
                    "Installer downloaded and opened — drag Shelf to Applications to finish"
                ))
                return phase
            }

            let expectedID = expectedBundleIdentifier
            let stagedAppURL = try await Task.detached(priority: .userInitiated) {
                try Self.stageAppBundle(
                    from: archiveURL,
                    kind: asset.kind,
                    workDir: workDir,
                    expectedBundleIdentifier: expectedID
                )
            }.value

            try Task.checkCancellation()
            try flushBeforeQuit?()

            let scriptURL = workDir.appendingPathComponent("install_update.sh")
            try Self.writeInstallerScript(to: scriptURL)

            keepWorkDirForHelper = true
            do {
                try Self.launchDetachedInstaller(
                    scriptURL: scriptURL,
                    appPID: ProcessInfo.processInfo.processIdentifier,
                    stagedAppURL: stagedAppURL,
                    targetAppURL: bundleURL,
                    workDir: workDir
                )
            } catch {
                keepWorkDirForHelper = false
                throw error
            }

            terminateApp()
        } catch is CancellationError {
            phase = .available(update)
        } catch {
            let message = Self.localizedErrorMessage(error, lang: lang)
            phase = .failed(update, message: message)
            onToast?(lang.tr("更新失败：\(message)", "Update failed: \(message)"))
        }

        return phase
    }

    // MARK: - Asset Selection & Validation

    nonisolated static func selectMacOSAsset(
        from assets: [GitHubRelease.Asset],
        arch: String = currentArch
    ) -> ReleaseAsset? {
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

            let hasArm = lower.contains("arm64") || lower.contains("aarch64") || lower.contains("apple-silicon")
            let hasIntel = lower.contains("x86_64") || lower.contains("x64") || lower.contains("amd64") || lower.contains("intel")
            let isUniversal = lower.contains("universal") || lower.contains("all")

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

    nonisolated static func canReplaceInPlace(bundleURL: URL) -> Bool {
        guard bundleURL.pathExtension.lowercased() == "app" else { return false }
        let standardized = bundleURL.standardized.path
        if standardized.contains("/AppTranslocation/") || standardized.hasPrefix("/Volumes/") {
            return false
        }
        let parentPath = bundleURL.deletingLastPathComponent().path
        return FileManager.default.isWritableFile(atPath: parentPath)
            && FileManager.default.isWritableFile(atPath: standardized)
    }

    nonisolated static func verifySHA256(fileURL: URL, expectedHex: String) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 256 * 1024)
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        let actualHex = digest.map { String(format: "%02x", $0) }.joined()
        return actualHex == expectedHex.lowercased()
    }

    nonisolated static func writeInstallerScript(to scriptURL: URL) throws {
        let script = """
        #!/bin/zsh
        APP_PID="$1"
        STAGED_APP="$2"
        TARGET_APP="$3"
        WORK_DIR="$4"

        elapsed=0
        while kill -0 "$APP_PID" 2>/dev/null; do
            /bin/sleep 0.1
            elapsed=$((elapsed + 1))
            if [ "$elapsed" -ge 200 ]; then
                /bin/rm -rf "$WORK_DIR"
                exit 1
            fi
        done

        BACKUP_APP="${TARGET_APP}.backup.$$"
        /bin/rm -rf "$BACKUP_APP"

        if /bin/mv "$TARGET_APP" "$BACKUP_APP"; then
            if /bin/mv "$STAGED_APP" "$TARGET_APP"; then
                /bin/rm -rf "$BACKUP_APP"
            else
                /bin/mv "$BACKUP_APP" "$TARGET_APP" 2>/dev/null || true
                /bin/rm -rf "$WORK_DIR"
                exit 1
            fi
        else
            /bin/rm -rf "$WORK_DIR"
            exit 1
        fi

        /usr/bin/xattr -cr "$TARGET_APP" 2>/dev/null || true
        if [ "${SHELF_UPDATER_SKIP_OPEN:-0}" != "1" ]; then
            /bin/sleep 0.25
            /usr/bin/open "$TARGET_APP"
        fi
        /bin/rm -rf "$WORK_DIR"
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
    }

    // MARK: - Staging & Process Helpers

    private nonisolated static func defaultFetchLatestRelease(currentVersion: AppVersion) async throws -> GitHubRelease {
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

    private nonisolated static func sanitizedArchiveName(_ raw: String) -> String {
        let leaf = URL(fileURLWithPath: raw).lastPathComponent
        if leaf.isEmpty || leaf == "." || leaf == ".." {
            return "Shelf-Update.dmg"
        }
        return leaf
    }

    private nonisolated static func stageAppBundle(
        from archiveURL: URL,
        kind: ReleaseAsset.Kind,
        workDir: URL,
        expectedBundleIdentifier: String
    ) throws -> URL {
        let stagedDir = workDir.appendingPathComponent("Staged", isDirectory: true)
        try FileManager.default.createDirectory(at: stagedDir, withIntermediateDirectories: true)
        let stagedAppURL = stagedDir.appendingPathComponent("Shelf.app", isDirectory: true)

        switch kind {
        case .dmg:
            let attach = try runProcess(
                "/usr/bin/hdiutil",
                arguments: ["attach", archiveURL.path, "-nobrowse", "-readonly", "-plist"]
            )
            guard attach.status == 0,
                  let mountPoint = parseMountPoint(from: attach.stdout)
            else {
                throw UpdaterError.mountFailed
            }
            defer {
                _ = try? runProcess("/usr/bin/hdiutil", arguments: ["detach", mountPoint, "-force", "-quiet"])
            }

            let mountURL = URL(fileURLWithPath: mountPoint, isDirectory: true)
            guard let sourceApp = findAppBundle(in: mountURL, maxDepth: 1) else {
                throw UpdaterError.missingAppBundle
            }
            let copyResult = try runProcess("/usr/bin/ditto", arguments: [sourceApp.path, stagedAppURL.path])
            guard copyResult.status == 0 else {
                throw UpdaterError.installFailed
            }

        case .zip:
            let extractDir = workDir.appendingPathComponent("Extracted", isDirectory: true)
            try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
            let unzipResult = try runProcess("/usr/bin/ditto", arguments: ["-x", "-k", archiveURL.path, extractDir.path])
            guard unzipResult.status == 0,
                  let sourceApp = findAppBundle(in: extractDir, maxDepth: 2)
            else {
                throw UpdaterError.missingAppBundle
            }
            let copyResult = try runProcess("/usr/bin/ditto", arguments: [sourceApp.path, stagedAppURL.path])
            guard copyResult.status == 0 else {
                throw UpdaterError.installFailed
            }
        }

        try validateStagedApp(at: stagedAppURL, expectedBundleIdentifier: expectedBundleIdentifier)
        return stagedAppURL
    }

    private nonisolated static func parseMountPoint(from plistData: Data) -> String? {
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil)
                as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]]
        else {
            return nil
        }
        for entity in entities {
            if let mountPoint = entity["mount-point"] as? String, !mountPoint.isEmpty {
                return mountPoint
            }
        }
        return nil
    }

    private nonisolated static func findAppBundle(in directory: URL, maxDepth: Int) -> URL? {
        guard maxDepth >= 1 else { return nil }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var candidates: [URL] = []
        var subdirectories: [URL] = []

        for entry in entries {
            let name = entry.lastPathComponent
            if name == "__MACOSX" { continue }
            guard let values = try? entry.resourceValues(forKeys: Set(keys)),
                  values.isSymbolicLink != true,
                  values.isDirectory == true
            else {
                continue
            }
            if entry.pathExtension.lowercased() == "app" {
                candidates.append(entry)
            } else {
                subdirectories.append(entry)
            }
        }

        if let preferred = candidates.first(where: { $0.lastPathComponent.caseInsensitiveCompare("Shelf.app") == .orderedSame }) {
            return preferred
        }
        if let first = candidates.first {
            return first
        }
        if maxDepth > 1 {
            for sub in subdirectories {
                if let nested = findAppBundle(in: sub, maxDepth: maxDepth - 1) {
                    return nested
                }
            }
        }
        return nil
    }

    private nonisolated static func validateStagedApp(at appURL: URL, expectedBundleIdentifier: String) throws {
        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let plist = NSDictionary(contentsOf: infoURL),
              let bundleID = plist["CFBundleIdentifier"] as? String,
              bundleID == expectedBundleIdentifier,
              let executable = plist["CFBundleExecutable"] as? String,
              !executable.isEmpty
        else {
            throw UpdaterError.invalidBundle
        }

        let execURL = appURL.appendingPathComponent("Contents/MacOS/\(executable)")
        guard FileManager.default.isExecutableFile(atPath: execURL.path) else {
            throw UpdaterError.invalidBundle
        }

        _ = try? runProcess("/usr/bin/xattr", arguments: ["-cr", appURL.path])
        let verify = try runProcess("/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", appURL.path])
        guard verify.status == 0 else {
            throw UpdaterError.invalidSignature
        }
    }

    private nonisolated static func launchDetachedInstaller(
        scriptURL: URL,
        appPID: Int32,
        stagedAppURL: URL,
        targetAppURL: URL,
        workDir: URL
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            "-c",
            "/usr/bin/nohup /bin/zsh \"$1\" \"$2\" \"$3\" \"$4\" \"$5\" >/dev/null 2>&1 &",
            "shelf-updater",
            scriptURL.path,
            String(appPID),
            stagedAppURL.path,
            targetAppURL.path,
            workDir.path
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdaterError.installFailed
        }
    }

    private nonisolated static func runProcess(
        _ executablePath: String,
        arguments: [String]
    ) throws -> (status: Int32, stdout: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        let output = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }

    private func upToDateToast(in lang: AppLanguage) -> String {
        lang.tr(
            "当前已是最新版本 (v\(currentVersion.description))",
            "Shelf is up to date (v\(currentVersion.description))"
        )
    }

    private nonisolated static func localizedErrorMessage(_ error: Error, lang: AppLanguage) -> String {
        if let updaterError = error as? UpdaterError {
            return updaterError.message(in: lang)
        }
        return error.localizedDescription
    }
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

private final class ReleaseDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destinationURL: URL
    private let onProgress: @MainActor @Sendable (Double?) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private var downloadTask: URLSessionDownloadTask?
    private var lastReportedFraction: Double?
    private var reportedIndeterminate = false
    private var completed = false

    private init(destinationURL: URL, onProgress: @escaping @MainActor @Sendable (Double?) -> Void) {
        self.destinationURL = destinationURL
        self.onProgress = onProgress
    }

    static func download(
        from url: URL,
        to destinationURL: URL,
        userAgent: String,
        onProgress: @escaping @MainActor @Sendable (Double?) -> Void
    ) async throws {
        let delegate = ReleaseDownloadDelegate(destinationURL: destinationURL, onProgress: onProgress)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.start(url: url, userAgent: userAgent, continuation: continuation)
            }
        } onCancel: {
            delegate.cancel()
        }
    }

    private func start(url: URL, userAgent: String, continuation: CheckedContinuation<Void, Error>) {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600

        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let task = session.downloadTask(with: request)
        let shouldCancelImmediately: Bool
        lock.lock()
        self.continuation = continuation
        self.session = session
        self.downloadTask = task
        shouldCancelImmediately = completed
        lock.unlock()

        if shouldCancelImmediately {
            task.cancel()
            session.invalidateAndCancel()
        } else {
            task.resume()
        }
    }

    private func cancel() {
        lock.lock()
        let task = downloadTask
        let continuation = self.continuation
        let session = self.session
        let alreadyCompleted = completed
        completed = true
        self.continuation = nil
        self.downloadTask = nil
        self.session = nil
        lock.unlock()

        task?.cancel()
        session?.invalidateAndCancel()
        if !alreadyCompleted {
            continuation?.resume(throwing: CancellationError())
        }
    }

    private func finish(with result: Result<Void, Error>) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let continuation = self.continuation
        let session = self.session
        self.continuation = nil
        self.downloadTask = nil
        self.session = nil
        lock.unlock()

        session?.finishTasksAndInvalidate()
        continuation?.resume(with: result)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        if totalBytesExpectedToWrite > 0 {
            let fraction = min(max(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 0), 1)
            let shouldReport: Bool
            lock.lock()
            if completed {
                shouldReport = false
            } else if let last = lastReportedFraction {
                shouldReport = abs(fraction - last) >= 0.01 || fraction >= 1.0
            } else {
                shouldReport = true
            }
            if shouldReport {
                lastReportedFraction = fraction
            }
            lock.unlock()

            if shouldReport {
                let callback = onProgress
                Task { @MainActor in
                    callback(fraction)
                }
            }
        } else {
            let shouldReport: Bool
            lock.lock()
            if !completed && !reportedIndeterminate {
                reportedIndeterminate = true
                shouldReport = true
            } else {
                shouldReport = false
            }
            lock.unlock()

            if shouldReport {
                let callback = onProgress
                Task { @MainActor in
                    callback(nil)
                }
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode)
        {
            finish(with: .failure(UpdaterError.downloadFailed(statusCode: http.statusCode)))
            return
        }

        do {
            let parent = destinationURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destinationURL)
            try FileManager.default.moveItem(at: location, to: destinationURL)
            finish(with: .success(()))
        } catch {
            finish(with: .failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else {
            finish(with: .failure(UpdaterError.downloadFailed(statusCode: nil)))
            return
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            finish(with: .failure(CancellationError()))
        } else {
            finish(with: .failure(error))
        }
    }
}
