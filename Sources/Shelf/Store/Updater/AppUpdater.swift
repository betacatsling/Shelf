import AppKit
import Foundation
import Observation

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

    nonisolated static let latestReleaseAPIURL = GitHubReleaseClient.latestReleaseAPIURL
    nonisolated static let releasesPageURL = GitHubReleaseClient.releasesPageURL

    #if arch(arm64)
    nonisolated static let currentArch = "arm64"
    #elseif arch(x86_64)
    nonisolated static let currentArch = "x86_64"
    #else
    nonisolated static let currentArch = "arm64"
    #endif

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
    @ObservationIgnored private nonisolated(unsafe) var activationObserver: NSObjectProtocol?

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
            try await GitHubReleaseClient.fetchLatestRelease(currentVersion: resolvedVersion)
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

    deinit {
        periodicCheckTask?.cancel()
        activeUpdateTask?.cancel()
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
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
            phase = previousAvailable.map { .available($0) } ?? .idle
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
            let safeName = AppBundleInstaller.sanitizedArchiveName(asset.name)
            let archiveURL = workDir.appendingPathComponent(safeName)

            try await assetDownloader(asset.downloadURL, archiveURL) { [weak self] progress in
                guard let self, case .downloading(let current, _) = self.phase else { return }
                self.phase = .downloading(current, progress: progress)
            }

            try Task.checkCancellation()

            if let expectedHex = asset.sha256Hex {
                let matches = try await Task.detached(priority: .utility) {
                    try AppBundleInstaller.verifySHA256(fileURL: archiveURL, expectedHex: expectedHex)
                }.value
                guard matches else {
                    throw UpdaterError.checksumMismatch
                }
            }

            try Task.checkCancellation()
            phase = .installing(update)

            guard AppBundleInstaller.canReplaceInPlace(bundleURL: bundleURL) else {
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
                try AppBundleInstaller.stageAppBundle(
                    from: archiveURL,
                    kind: asset.kind,
                    workDir: workDir,
                    expectedBundleIdentifier: expectedID
                )
            }.value

            try Task.checkCancellation()
            try flushBeforeQuit?()

            let scriptURL = workDir.appendingPathComponent("install_update.sh")
            try AppBundleInstaller.writeInstallerScript(to: scriptURL)

            keepWorkDirForHelper = true
            do {
                try AppBundleInstaller.launchDetachedInstaller(
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

    // MARK: - Facade Forwarders (Preserves Public API & Test Surface)

    nonisolated static func selectMacOSAsset(
        from assets: [GitHubRelease.Asset],
        arch: String = currentArch
    ) -> ReleaseAsset? {
        GitHubReleaseClient.selectMacOSAsset(from: assets, arch: arch)
    }

    nonisolated static func canReplaceInPlace(bundleURL: URL) -> Bool {
        AppBundleInstaller.canReplaceInPlace(bundleURL: bundleURL)
    }

    nonisolated static func verifySHA256(fileURL: URL, expectedHex: String) throws -> Bool {
        try AppBundleInstaller.verifySHA256(fileURL: fileURL, expectedHex: expectedHex)
    }

    nonisolated static func writeInstallerScript(to scriptURL: URL) throws {
        try AppBundleInstaller.writeInstallerScript(to: scriptURL)
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
