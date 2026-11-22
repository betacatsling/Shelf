import CryptoKit
import Foundation

enum AppBundleInstaller {
    static func canReplaceInPlace(bundleURL: URL) -> Bool {
        guard bundleURL.pathExtension.lowercased() == "app" else { return false }
        let standardized = bundleURL.standardized.path
        if standardized.contains("/AppTranslocation/") || standardized.hasPrefix("/Volumes/") {
            return false
        }
        let parentPath = bundleURL.deletingLastPathComponent().path
        return FileManager.default.isWritableFile(atPath: parentPath)
            && FileManager.default.isWritableFile(atPath: standardized)
    }

    static func verifySHA256(fileURL: URL, expectedHex: String) throws -> Bool {
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

    static func sanitizedArchiveName(_ raw: String) -> String {
        let leaf = URL(fileURLWithPath: raw).lastPathComponent
        if leaf.isEmpty || leaf == "." || leaf == ".." {
            return "Shelf-Update.dmg"
        }
        return leaf
    }

    static func stageAppBundle(
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

    static func writeInstallerScript(to scriptURL: URL) throws {
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

    static func launchDetachedInstaller(
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

    private static func parseMountPoint(from plistData: Data) -> String? {
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

    private static func findAppBundle(in directory: URL, maxDepth: Int) -> URL? {
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

    private static func validateStagedApp(at appURL: URL, expectedBundleIdentifier: String) throws {
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

    private static func runProcess(
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
}
