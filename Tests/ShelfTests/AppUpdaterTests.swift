import CryptoKit
import Foundation
import Testing
@testable import Shelf

struct AppUpdaterTests {
    @Test func testAppVersionParsingAndComparison() {
        #expect(AppVersion(parsing: "v1.2.3") == AppVersion(parsing: "1.2.3"))
        #expect(AppVersion(parsing: "1.2.3") == AppVersion(parsing: "1.2.3.0"))
        #expect(AppVersion(parsing: "V1.2.3+build42") == AppVersion(parsing: "1.2.3"))

        let v123 = AppVersion(parsing: "v1.2.3")!
        let v1230 = AppVersion(parsing: "1.2.3.0")!
        #expect(Set([v123, v1230]).count == 1)

        #expect(AppVersion(parsing: "v1.2.4")! > v123)
        #expect(AppVersion(parsing: "v1.10.0")! > AppVersion(parsing: "v1.2.9")!)
        #expect(AppVersion(parsing: "2.0")! > AppVersion(parsing: "1.9.9")!)
        #expect(AppVersion(parsing: "1.2.4")! > AppVersion(parsing: "1.2.4-beta.1")!)
        #expect(AppVersion(parsing: "1.2.4-beta.2")! > AppVersion(parsing: "1.2.4-beta.1")!)
        #expect(AppVersion(parsing: "1.2.4-beta.1")! > v123)

        #expect(AppVersion(parsing: "") == nil)
        #expect(AppVersion(parsing: "latest") == nil)
        #expect(AppVersion(parsing: "v1.x.0") == nil)
        #expect(AppVersion(parsing: "1.2.3-") == nil)
    }

    @Test func testMultiPlatformAssetSelectionAndDigestParsing() throws {
        let json = """
        {
          "tag_name": "v1.2.4",
          "name": "Shelf v1.2.4",
          "body": "Release notes",
          "html_url": "https://github.com/betacatsling/Shelf/releases/tag/v1.2.4",
          "draft": false,
          "prerelease": false,
          "assets": [
            {
              "name": "Shelf-v1.2.4-Windows-arm64.zip",
              "browser_download_url": "https://github.com/betacatsling/Shelf/releases/download/v1.2.4/Shelf-v1.2.4-Windows-arm64.zip",
              "size": 100000000
            },
            {
              "name": "Shelf-v1.2.4-Windows-x64.zip",
              "browser_download_url": "https://github.com/betacatsling/Shelf/releases/download/v1.2.4/Shelf-v1.2.4-Windows-x64.zip",
              "size": 100000000
            },
            {
              "name": "shelf-1.2.4-1.fc45.noarch.rpm",
              "browser_download_url": "https://github.com/betacatsling/Shelf/releases/download/v1.2.4/shelf-1.2.4-1.fc45.noarch.rpm",
              "size": 500000
            },
            {
              "name": "Shelf-v1.2.4-Android.apk",
              "browser_download_url": "https://github.com/betacatsling/Shelf/releases/download/v1.2.4/Shelf-v1.2.4-Android.apk",
              "size": 12000000
            },
            {
              "name": "Shelf-v1.2.4-macOS-arm64.dmg.sha256",
              "browser_download_url": "https://github.com/betacatsling/Shelf/releases/download/v1.2.4/Shelf-v1.2.4-macOS-arm64.dmg.sha256",
              "size": 128
            },
            {
              "name": "Shelf-v1.2.4-macOS-arm64.dmg",
              "browser_download_url": "https://github.com/betacatsling/Shelf/releases/download/v1.2.4/Shelf-v1.2.4-macOS-arm64.dmg",
              "size": 4121253,
              "digest": "sha256:02d9c5e76006e7817be8942e9db6cb5d36cbb350d8610b2e46db4540887747d8"
            }
          ]
        }
        """

        let release = try JSONDecoder().decode(GitHubRelease.self, from: Data(json.utf8))
        let armAsset = try #require(AppUpdater.selectMacOSAsset(from: release.assets, arch: "arm64"))
        #expect(armAsset.name == "Shelf-v1.2.4-macOS-arm64.dmg")
        #expect(armAsset.kind == .dmg)
        #expect(armAsset.sha256Hex == "02d9c5e76006e7817be8942e9db6cb5d36cbb350d8610b2e46db4540887747d8")

        // arm64-only macOS asset must not be selected for x86_64
        #expect(AppUpdater.selectMacOSAsset(from: release.assets, arch: "x86_64") == nil)

        // Release with only non-macOS assets must return nil (never pick Windows-arm64.zip)
        let nonMacAssets = Array(release.assets.dropLast(2))
        #expect(AppUpdater.selectMacOSAsset(from: nonMacAssets, arch: "arm64") == nil)
        #expect(AppUpdater.selectMacOSAsset(from: nonMacAssets, arch: "x86_64") == nil)
    }

    @MainActor
    @Test func testCheckStateTransitionsAndToasts() async {
        var toasts: [String] = []
        let upToDateRelease = GitHubRelease(
            tag_name: "v1.2.3",
            html_url: "https://github.com/betacatsling/Shelf/releases/tag/v1.2.3",
            assets: []
        )

        let upToDateUpdater = AppUpdater(
            currentVersionString: "1.2.3",
            releaseFetcher: { upToDateRelease }
        )
        upToDateUpdater.languageProvider = { .en }
        upToDateUpdater.onToast = { toasts.append($0) }

        await upToDateUpdater.checkForUpdatesNow(userInitiated: false)
        #expect(upToDateUpdater.phase == .idle)
        #expect(toasts.isEmpty)

        await upToDateUpdater.checkForUpdatesNow(userInitiated: true)
        #expect(upToDateUpdater.phase == .idle)
        #expect(toasts == ["Shelf is up to date (v1.2.3)"])

        let draftRelease = GitHubRelease(
            tag_name: "v1.2.5",
            html_url: "https://github.com/betacatsling/Shelf/releases/tag/v1.2.5",
            draft: true,
            prerelease: false,
            assets: []
        )
        let draftUpdater = AppUpdater(
            currentVersionString: "1.2.3",
            releaseFetcher: { draftRelease }
        )
        await draftUpdater.checkForUpdatesNow(userInitiated: false)
        #expect(draftUpdater.phase == .idle)

        let prerelease = GitHubRelease(
            tag_name: "v1.2.5",
            html_url: "https://github.com/betacatsling/Shelf/releases/tag/v1.2.5",
            draft: false,
            prerelease: true,
            assets: []
        )
        let prereleaseUpdater = AppUpdater(
            currentVersionString: "1.2.3",
            releaseFetcher: { prerelease }
        )
        await prereleaseUpdater.checkForUpdatesNow(userInitiated: false)
        #expect(prereleaseUpdater.phase == .idle)

        let newerRelease = GitHubRelease(
            tag_name: "1.2.4",
            html_url: "https://github.com/betacatsling/Shelf/releases/tag/v1.2.4",
            assets: [
                .init(
                    name: "Shelf-v1.2.4-macOS-arm64.dmg",
                    browser_download_url: "https://github.com/betacatsling/Shelf/releases/download/v1.2.4/Shelf-v1.2.4-macOS-arm64.dmg"
                )
            ]
        )
        let newerUpdater = AppUpdater(
            currentVersionString: "1.2.3",
            releaseFetcher: { newerRelease }
        )
        await newerUpdater.checkForUpdatesNow(userInitiated: false)
        if case .available(let update) = newerUpdater.phase {
            #expect(update.displayTag == "v1.2.4")
            #expect(update.asset?.name == "Shelf-v1.2.4-macOS-arm64.dmg")
        } else {
            Issue.record("Expected .available phase, got \(newerUpdater.phase)")
        }
    }

    @MainActor
    @Test func testChecksumMismatchTransitionsToFailed() async {
        let wrongDigest = String(repeating: "a", count: 64)
        let release = GitHubRelease(
            tag_name: "v1.2.4",
            html_url: "https://github.com/betacatsling/Shelf/releases/tag/v1.2.4",
            assets: [
                .init(
                    name: "Shelf-v1.2.4-macOS-arm64.dmg",
                    browser_download_url: "https://github.com/betacatsling/Shelf/releases/download/v1.2.4/Shelf-v1.2.4-macOS-arm64.dmg",
                    digest: "sha256:\(wrongDigest)"
                )
            ]
        )

        var toasts: [String] = []
        let updater = AppUpdater(
            currentVersionString: "1.2.3",
            releaseFetcher: { release },
            assetDownloader: { _, destinationURL, onProgress in
                await onProgress(0.5)
                try Data("corrupt dmg bytes".utf8).write(to: destinationURL)
                await onProgress(1.0)
            }
        )
        updater.languageProvider = { .en }
        updater.onToast = { toasts.append($0) }

        await updater.checkForUpdatesNow(userInitiated: false)
        await updater.performUpdateNow()

        if case .failed(let update, let message) = updater.phase {
            #expect(update.displayTag == "v1.2.4")
            #expect(message == "Checksum verification failed")
        } else {
            Issue.record("Expected .failed phase, got \(updater.phase)")
        }
        #expect(toasts == ["Update failed: Checksum verification failed"])
    }

    @MainActor
    @Test func testNonReplaceableBundleFallsBackToDownloadsAndOpensInstaller() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("shelf-updater-fallback-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let downloadsDir = tempRoot.appendingPathComponent("Downloads", isDirectory: true)

        let payload = Data("fake dmg payload".utf8)
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let release = GitHubRelease(
            tag_name: "v1.2.4",
            html_url: "https://github.com/betacatsling/Shelf/releases/tag/v1.2.4",
            assets: [
                .init(
                    name: "Shelf-v1.2.4-macOS-arm64.dmg",
                    browser_download_url: "https://github.com/betacatsling/Shelf/releases/download/v1.2.4/Shelf-v1.2.4-macOS-arm64.dmg",
                    digest: "sha256:\(digest)"
                )
            ]
        )

        var openedURLs: [URL] = []
        var toasts: [String] = []
        let updater = AppUpdater(
            currentVersionString: "1.2.3",
            bundleURL: URL(fileURLWithPath: "/Volumes/Shelf/Shelf.app", isDirectory: true),
            downloadsDirectory: downloadsDir,
            releaseFetcher: { release },
            assetDownloader: { _, destinationURL, onProgress in
                await onProgress(1.0)
                try payload.write(to: destinationURL)
            },
            openURL: { openedURLs.append($0) }
        )
        updater.languageProvider = { .en }
        updater.onToast = { toasts.append($0) }

        await updater.checkForUpdatesNow(userInitiated: false)
        await updater.performUpdateNow()

        let expectedDownload = downloadsDir.appendingPathComponent("Shelf-v1.2.4-macOS-arm64.dmg")
        #expect(FileManager.default.fileExists(atPath: expectedDownload.path))
        #expect(try Data(contentsOf: expectedDownload) == payload)
        #expect(openedURLs == [expectedDownload])
        if case .available(let update) = updater.phase {
            #expect(update.displayTag == "v1.2.4")
        } else {
            Issue.record("Expected .available phase after fallback open, got \(updater.phase)")
        }
        #expect(toasts == ["Installer downloaded and opened — drag Shelf to Applications to finish"])
    }

    @Test func testInstallerScriptReplacesTargetAppAfterProcessExitAndCleansUp() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shelf-installer-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let targetDir = root.appendingPathComponent("Target", isDirectory: true)
        let targetApp = targetDir.appendingPathComponent("Shelf.app", isDirectory: true)
        let workDir = root.appendingPathComponent("Work", isDirectory: true)
        let stagedApp = workDir.appendingPathComponent("Staged/Shelf.app", isDirectory: true)

        try FileManager.default.createDirectory(
            at: targetApp.appendingPathComponent("Contents", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: stagedApp.appendingPathComponent("Contents", isDirectory: true),
            withIntermediateDirectories: true
        )

        let targetMarker = targetApp.appendingPathComponent("Contents/version.txt")
        let stagedMarker = stagedApp.appendingPathComponent("Contents/version.txt")
        try "1.2.3".write(to: targetMarker, atomically: true, encoding: .utf8)
        try "1.2.4".write(to: stagedMarker, atomically: true, encoding: .utf8)

        let scriptURL = workDir.appendingPathComponent("install_update.sh")
        try AppUpdater.writeInstallerScript(to: scriptURL)

        let sleepProc = Process()
        sleepProc.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleepProc.arguments = ["0.15"]
        try sleepProc.run()

        let installerProc = Process()
        installerProc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        installerProc.arguments = [
            scriptURL.path,
            String(sleepProc.processIdentifier),
            stagedApp.path,
            targetApp.path,
            workDir.path
        ]
        var env = ProcessInfo.processInfo.environment
        env["SHELF_UPDATER_SKIP_OPEN"] = "1"
        installerProc.environment = env
        installerProc.standardInput = FileHandle.nullDevice
        installerProc.standardOutput = FileHandle.nullDevice
        installerProc.standardError = FileHandle.nullDevice

        try installerProc.run()
        sleepProc.waitUntilExit()
        installerProc.waitUntilExit()

        #expect(installerProc.terminationStatus == 0)
        #expect(try String(contentsOf: targetMarker, encoding: .utf8) == "1.2.4")

        let remainingTargetEntries = try FileManager.default.contentsOfDirectory(atPath: targetDir.path)
        #expect(remainingTargetEntries == ["Shelf.app"])
        #expect(!FileManager.default.fileExists(atPath: workDir.path))
    }

    @Test func testAppVersionPrereleaseStrictWeakOrdering() throws {
        let a = try #require(AppVersion(parsing: "1.0.0-01"))
        let b = try #require(AppVersion(parsing: "1.0.0-1"))
        #expect(a == b)
        #expect(!(a < b))
        #expect(!(b < a))
        #expect(Set([a, b]).count == 1)
    }

    @Test func testInstallerFilenameDoesNotFalseMatchUniversalArch() {
        let intelInstaller = GitHubRelease.Asset(
            name: "Shelf-Installer-x86_64.dmg",
            browser_download_url: "https://github.com/betacatsling/Shelf/releases/download/v1.2.7/Shelf-Installer-x86_64.dmg"
        )
        #expect(AppUpdater.selectMacOSAsset(from: [intelInstaller], arch: "arm64") == nil)
        #expect(AppUpdater.selectMacOSAsset(from: [intelInstaller], arch: "x86_64")?.name == intelInstaller.name)
    }

    @MainActor
    @Test func testAutomaticPeriodicChecksDiscoverNewRelease() async {
        final class Counter: @unchecked Sendable {
            var count = 0
        }
        let counter = Counter()
        let updater = AppUpdater(
            currentVersionString: "1.3.1",
            initialCheckDelay: .milliseconds(10),
            automaticCheckInterval: .milliseconds(30),
            releaseFetcher: {
                counter.count += 1
                if counter.count == 1 {
                    return GitHubRelease(
                        tag_name: "v1.3.1",
                        html_url: "https://github.com/betacatsling/Shelf/releases/tag/v1.3.1",
                        assets: []
                    )
                }
                return GitHubRelease(
                    tag_name: "v1.3.2",
                    html_url: "https://github.com/betacatsling/Shelf/releases/tag/v1.3.2",
                    assets: [
                        .init(
                            name: "Shelf-v1.3.2-macOS-arm64.dmg",
                            browser_download_url: "https://github.com/betacatsling/Shelf/releases/download/v1.3.2/Shelf-v1.3.2-macOS-arm64.dmg"
                        )
                    ]
                )
            }
        )

        updater.startAutomaticChecksIfNeeded()

        for _ in 0..<40 {
            if updater.availableUpdate?.displayTag == "v1.3.2" { break }
            try? await Task.sleep(for: .milliseconds(20))
        }

        #expect(counter.count >= 2)
        #expect(updater.availableUpdate?.displayTag == "v1.3.2")
    }
}
