import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class CoverManager {
    static let shared = CoverManager()

    private let fullCache = NSCache<NSString, NSImage>()
    private let thumbNSImageCache = NSCache<NSString, NSImage>()

    /// Lock-protected pre-decoded CGImage cache for 120Hz zero-IO collection view scrolling.
    private let cacheLock = NSLock()
    private nonisolated(unsafe) var cgThumbCache: [String: CGImage] = [:]
    private nonisolated(unsafe) var inFlightLoads: [String: [@MainActor (CGImage?) -> Void]] = [:]
    private var placeholderCache: [String: CGImage] = [:]

    let coversDirectory: URL
    let thumbnailsDirectory: URL

    private nonisolated static let thumbMaxPixel: Int = 440

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let baseDir = appSupport.appendingPathComponent("Shelf", isDirectory: true)
        let coversDir = baseDir.appendingPathComponent("Covers", isDirectory: true)
        let thumbsDir = baseDir.appendingPathComponent("Thumbnails", isDirectory: true)
        self.coversDirectory = coversDir
        self.thumbnailsDirectory = thumbsDir

        try? FileManager.default.createDirectory(at: coversDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: thumbsDir, withIntermediateDirectories: true)
        fullCache.countLimit = 200
        thumbNSImageCache.countLimit = 500
    }

    // MARK: - Zero-Blocking CGImage Grid Cache (120Hz Scroll Path)

    /// O(1) memory-only lookup. Never touches disk or decodes on the main thread.
    nonisolated func cachedGridCGImage(for fileName: String?) -> CGImage? {
        guard let fileName, !fileName.isEmpty else { return nil }
        cacheLock.lock()
        let img = cgThumbCache[fileName]
        cacheLock.unlock()
        return img
    }

    /// Loads and pre-decodes a grid thumbnail on a background thread if not already in memory.
    func loadGridCGImageAsync(
        for fileName: String,
        completion: @escaping @MainActor (CGImage?) -> Void
    ) {
        guard !fileName.isEmpty else {
            completion(nil)
            return
        }
        if let hit = cachedGridCGImage(for: fileName) {
            completion(hit)
            return
        }

        cacheLock.lock()
        if var callbacks = inFlightLoads[fileName] {
            callbacks.append(completion)
            inFlightLoads[fileName] = callbacks
            cacheLock.unlock()
            return
        }
        inFlightLoads[fileName] = [completion]
        cacheLock.unlock()

        let coversDir = self.coversDirectory
        let thumbsDir = self.thumbnailsDirectory

        Task.detached(priority: .userInitiated) { [weak self] in
            let decoded = Self.loadOrBuildDecodedThumbnail(
                fileName: fileName,
                coversDir: coversDir,
                thumbsDir: thumbsDir
            )
            guard let self else { return }

            let callbacks: [@MainActor (CGImage?) -> Void] = self.cacheLock.withLock {
                if let decoded {
                    self.cgThumbCache[fileName] = decoded
                }
                return self.inFlightLoads.removeValue(forKey: fileName) ?? []
            }

            await MainActor.run {
                for cb in callbacks {
                    cb(decoded)
                }
            }
        }
    }

    /// Pre-warms all library cover thumbnails in parallel off the main thread right at app launch.
    func preloadThumbnails(for fileNames: [String]) {
        let unique = Array(Set(fileNames.filter { !$0.isEmpty }))
        guard !unique.isEmpty else { return }

        let missing = unique.filter { cachedGridCGImage(for: $0) == nil }
        guard !missing.isEmpty else { return }

        let coversDir = self.coversDirectory
        let thumbsDir = self.thumbnailsDirectory

        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let maxConcurrency = 6
            await withTaskGroup(of: (String, CGImage?).self) { group in
                var iterator = missing.makeIterator()
                for _ in 0..<min(maxConcurrency, missing.count) {
                    if let name = iterator.next() {
                        group.addTask {
                            let cg = Self.loadOrBuildDecodedThumbnail(
                                fileName: name,
                                coversDir: coversDir,
                                thumbsDir: thumbsDir
                            )
                            return (name, cg)
                        }
                    }
                }

                while let (name, cg) = await group.next() {
                    if let cg {
                        self.cacheLock.withLock {
                            self.cgThumbCache[name] = cg
                        }
                    }
                    if let nextName = iterator.next() {
                        group.addTask {
                            let nextCG = Self.loadOrBuildDecodedThumbnail(
                                fileName: nextName,
                                coversDir: coversDir,
                                thumbsDir: thumbsDir
                            )
                            return (nextName, nextCG)
                        }
                    }
                }
            }
        }
    }

    private nonisolated static func loadOrBuildDecodedThumbnail(
        fileName: String,
        coversDir: URL,
        thumbsDir: URL
    ) -> CGImage? {
        let thumbURL = thumbsDir.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: thumbURL.path),
           let cg = decodeOpaqueBitmap(at: thumbURL, maxPixel: thumbMaxPixel) {
            return cg
        }

        let sourceURL = coversDir.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: sourceURL.path),
              let cg = decodeOpaqueBitmap(at: sourceURL, maxPixel: thumbMaxPixel)
        else {
            return nil
        }

        writeJPEGThumbnail(cgImage: cg, to: thumbURL)
        return cg
    }

    private nonisolated static func decodeOpaqueBitmap(at url: URL, maxPixel: Int) -> CGImage? {
        let srcOpts: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, srcOpts as CFDictionary) else {
            return nil
        }

        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let thumbCG = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOpts as CFDictionary) else {
            return nil
        }

        let dstW = max(1, thumbCG.width)
        let dstH = max(1, thumbCG.height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: dstW,
            height: dstH,
            bitsPerComponent: 8,
            bytesPerRow: dstW * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return thumbCG
        }
        ctx.interpolationQuality = .medium
        ctx.draw(thumbCG, in: CGRect(x: 0, y: 0, width: dstW, height: dstH))
        return ctx.makeImage() ?? thumbCG
    }

    private nonisolated static func writeJPEGThumbnail(cgImage: CGImage, to destURL: URL) {
        guard let dest = CGImageDestinationCreateWithURL(
            destURL as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.85]
        CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
        CGImageDestinationFinalize(dest)
    }

    // MARK: - Editorial Placeholder CGImage Cache (Fallback for Uncovered Items)

    func editorialPlaceholderCGImage(
        title: String,
        category: MediaCategory,
        subtag: String,
        paletteSeed: Int,
        language: AppLanguage
    ) -> CGImage? {
        let key = "\(paletteSeed)|\(category.rawValue)|\(subtag)|\(language.rawValue)|\(title)"
        if let cached = placeholderCache[key] {
            return cached
        }

        let w = 320
        let h = 480
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return nil
        }

        let palettes: [([CGFloat], [CGFloat], [CGFloat], [CGFloat])] = [
            ([0.16, 0.22, 0.45, 1], [0.10, 0.13, 0.28, 1], [0.06, 0.07, 0.15, 1], [0.42, 0.58, 0.98, 1]),
            ([0.12, 0.34, 0.30, 1], [0.08, 0.21, 0.20, 1], [0.04, 0.11, 0.12, 1], [0.32, 0.85, 0.68, 1]),
            ([0.44, 0.15, 0.24, 1], [0.26, 0.09, 0.16, 1], [0.13, 0.05, 0.09, 1], [0.96, 0.42, 0.54, 1]),
            ([0.46, 0.27, 0.14, 1], [0.28, 0.16, 0.09, 1], [0.14, 0.08, 0.05, 1], [0.96, 0.68, 0.32, 1]),
            ([0.32, 0.18, 0.44, 1], [0.19, 0.11, 0.29, 1], [0.09, 0.06, 0.16, 1], [0.75, 0.48, 0.98, 1]),
            ([0.13, 0.31, 0.42, 1], [0.08, 0.19, 0.28, 1], [0.05, 0.10, 0.16, 1], [0.35, 0.76, 0.96, 1]),
            ([0.28, 0.25, 0.22, 1], [0.16, 0.15, 0.14, 1], [0.08, 0.08, 0.08, 1], [0.88, 0.74, 0.50, 1]),
            ([0.48, 0.21, 0.19, 1], [0.29, 0.12, 0.14, 1], [0.14, 0.07, 0.09, 1], [0.98, 0.55, 0.38, 1])
        ]
        let p = palettes[abs(paletteSeed) % palettes.count]

        if let grad = CGGradient(
            colorSpace: colorSpace,
            colorComponents: p.0 + p.1 + p.2,
            locations: [0.0, 0.52, 1.0],
            count: 3
        ) {
            ctx.drawLinearGradient(
                grad,
                start: CGPoint(x: 0, y: CGFloat(h)),
                end: CGPoint(x: CGFloat(w), y: 0),
                options: []
            )
        }

        if let radial = CGGradient(
            colorSpace: colorSpace,
            colorComponents: [p.3[0], p.3[1], p.3[2], 0.30, p.3[0], p.3[1], p.3[2], 0.0],
            locations: [0.0, 1.0],
            count: 2
        ) {
            let center = CGPoint(x: CGFloat(w) * 0.72, y: CGFloat(h) * 0.72)
            ctx.drawRadialGradient(
                radial,
                startCenter: center,
                startRadius: 6,
                endCenter: center,
                endRadius: 210,
                options: []
            )
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

        // Subtle center rings
        let centerPt = NSPoint(x: CGFloat(w) * 0.5, y: CGFloat(h) * 0.55)
        let ring1 = NSBezierPath(ovalIn: NSRect(x: centerPt.x - 86, y: centerPt.y - 86, width: 172, height: 172))
        NSColor.white.withAlphaComponent(0.09).setStroke()
        ring1.lineWidth = 1.6
        ring1.stroke()

        let ring2 = NSBezierPath(ovalIn: NSRect(x: centerPt.x - 62, y: centerPt.y - 62, width: 124, height: 124))
        NSColor(srgbRed: p.3[0], green: p.3[1], blue: p.3[2], alpha: 0.18).setStroke()
        ring2.lineWidth = 1.4
        ring2.stroke()

        if let sym = NSImage(systemSymbolName: category.systemImage, accessibilityDescription: nil) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 48, weight: .light)
            if let tinted = sym.withSymbolConfiguration(cfg) {
                let sz = tinted.size
                let symRect = NSRect(
                    x: centerPt.x - sz.width * 0.5,
                    y: centerPt.y - sz.height * 0.5,
                    width: sz.width,
                    height: sz.height
                )
                tinted.draw(in: symRect, from: .zero, operation: .sourceOver, fraction: 0.45)
            }
        }

        // Top pill tag
        let pillText = subtag.isEmpty
            ? category.title(in: language)
            : MediaCategory.localizedSubtag(subtag, in: language)
        let pillAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 18, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.86)
        ]
        let pillSize = (pillText as NSString).size(withAttributes: pillAttrs)
        let pillRect = NSRect(
            x: 24,
            y: CGFloat(h) - 26 - (pillSize.height + 12),
            width: min(CGFloat(w) - 48, pillSize.width + 26),
            height: pillSize.height + 12
        )
        let pillPath = NSBezierPath(roundedRect: pillRect, xRadius: pillRect.height * 0.5, yRadius: pillRect.height * 0.5)
        NSColor.white.withAlphaComponent(0.13).setFill()
        pillPath.fill()
        (pillText as NSString).draw(
            in: NSRect(x: pillRect.minX + 13, y: pillRect.minY + 6, width: pillRect.width - 26, height: pillSize.height),
            withAttributes: pillAttrs
        )

        // Bottom title & accent bar
        let displayTitle = title.isEmpty ? language.tr("未命名作品", "Untitled") : title
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        para.lineSpacing = 3
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 27, weight: .bold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.95),
            .paragraphStyle: para
        ]
        let maxTitleRect = NSRect(x: 24, y: 26, width: CGFloat(w) - 48, height: 118)
        let bound = (displayTitle as NSString).boundingRect(
            with: maxTitleRect.size,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: titleAttrs
        )
        let titleH = min(118, ceil(bound.height))
        let drawTitleRect = NSRect(x: 24, y: 26, width: CGFloat(w) - 48, height: titleH)
        (displayTitle as NSString).draw(with: drawTitleRect, options: [.usesLineFragmentOrigin], attributes: titleAttrs)

        let barRect = NSRect(x: 24, y: 26 + titleH + 12, width: 42, height: 3)
        NSColor(srgbRed: p.3[0], green: p.3[1], blue: p.3[2], alpha: 0.72).setFill()
        NSBezierPath(rect: barRect).fill()

        NSGraphicsContext.restoreGraphicsState()

        guard let cg = ctx.makeImage() else { return nil }
        placeholderCache[key] = cg
        return cg
    }

    // MARK: - SwiftUI NSImage Accessors (Detail Panel & Sheets)

    func gridThumbnail(for fileName: String?) -> NSImage? {
        guard let fileName, !fileName.isEmpty else { return nil }
        if let cached = thumbNSImageCache.object(forKey: fileName as NSString) {
            return cached
        }
        if let cg = cachedGridCGImage(for: fileName) {
            let nsImg = NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
            thumbNSImageCache.setObject(nsImg, forKey: fileName as NSString)
            return nsImg
        }
        let coversDir = self.coversDirectory
        let thumbsDir = self.thumbnailsDirectory
        guard let cg = Self.loadOrBuildDecodedThumbnail(fileName: fileName, coversDir: coversDir, thumbsDir: thumbsDir) else {
            return nil
        }
        cacheLock.lock()
        cgThumbCache[fileName] = cg
        cacheLock.unlock()
        let nsImg = NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
        thumbNSImageCache.setObject(nsImg, forKey: fileName as NSString)
        return nsImg
    }

    func image(for fileName: String?) -> NSImage? {
        guard let fileName, !fileName.isEmpty else { return nil }
        if let cached = fullCache.object(forKey: fileName as NSString) {
            return cached
        }
        let fileURL = coversDirectory.appendingPathComponent(fileName)
        guard let raw = NSImage(contentsOf: fileURL) else { return nil }
        let decoded = rasterizedBitmap(from: raw, maxPixelDimension: 960)
        fullCache.setObject(decoded, forKey: fileName as NSString)
        return decoded
    }

    // MARK: - Save & Delete

    func saveImage(_ sourceImage: NSImage, replacing oldFileName: String? = nil) -> String? {
        let resized = rasterizedBitmap(from: sourceImage, maxPixelDimension: 960)
        guard let tiffData = resized.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.88])
        else {
            return nil
        }

        let newFileName = "cover-\(UUID().uuidString).jpg"
        let destURL = coversDirectory.appendingPathComponent(newFileName)

        do {
            try jpegData.write(to: destURL, options: .atomic)
            fullCache.setObject(resized, forKey: newFileName as NSString)

            if let thumbCG = Self.decodeOpaqueBitmap(at: destURL, maxPixel: Self.thumbMaxPixel) {
                let thumbURL = thumbnailsDirectory.appendingPathComponent(newFileName)
                Self.writeJPEGThumbnail(cgImage: thumbCG, to: thumbURL)
                cacheLock.lock()
                cgThumbCache[newFileName] = thumbCG
                cacheLock.unlock()
                let thumbNS = NSImage(
                    cgImage: thumbCG,
                    size: NSSize(width: thumbCG.width / 2, height: thumbCG.height / 2)
                )
                thumbNSImageCache.setObject(thumbNS, forKey: newFileName as NSString)
            }

            if let oldFileName {
                removeCover(fileName: oldFileName)
            }
            return newFileName
        } catch {
            return nil
        }
    }

    func saveImageFromFileURL(_ url: URL, replacing oldFileName: String? = nil) -> String? {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        guard let img = NSImage(contentsOf: url) else { return nil }
        return saveImage(img, replacing: oldFileName)
    }

    func downloadAndSaveImage(from urlString: String, replacing oldFileName: String? = nil) async throws -> String {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            throw CoverError.invalidURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw CoverError.downloadFailed
        }
        guard let img = NSImage(data: data) else {
            throw CoverError.invalidImageData
        }
        guard let saved = saveImage(img, replacing: oldFileName) else {
            throw CoverError.saveFailed
        }
        return saved
    }

    func removeCover(fileName: String?) {
        guard let fileName, !fileName.isEmpty else { return }
        fullCache.removeObject(forKey: fileName as NSString)
        thumbNSImageCache.removeObject(forKey: fileName as NSString)
        cacheLock.lock()
        cgThumbCache.removeValue(forKey: fileName)
        cacheLock.unlock()

        try? FileManager.default.removeItem(at: coversDirectory.appendingPathComponent(fileName))
        try? FileManager.default.removeItem(at: thumbnailsDirectory.appendingPathComponent(fileName))
    }

    func chooseLocalImagePanel(lang: AppLanguage = .zh) -> URL? {
        let panel = NSOpenPanel()
        panel.title = lang.tr("选择海报封面图片", "Choose Cover Image")
        panel.prompt = lang.tr("设为封面", "Set Cover")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image, .jpeg, .png, .webP, .heic, .gif, .tiff]
        return panel.runModal() == .OK ? panel.url : nil
    }

    enum PasteboardResult {
        case image(NSImage)
        case remoteURL(String)
        case fileURL(URL)
        case empty
    }

    func inspectPasteboard() -> PasteboardResult {
        let pb = NSPasteboard.general

        if let img = NSImage(pasteboard: pb) {
            return .image(img)
        }

        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let first = urls.first {
            if first.isFileURL {
                return .fileURL(first)
            } else if first.scheme == "http" || first.scheme == "https" {
                return .remoteURL(first.absoluteString)
            }
        }

        if let str = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           let url = URL(string: str),
           (url.scheme == "http" || url.scheme == "https") {
            return .remoteURL(str)
        }

        return .empty
    }

    func extractDroppedCover(from providers: [NSItemProvider], completion: @escaping @MainActor (Result<String, Error>) -> Void) -> Bool {
        guard let provider = providers.first else { return false }

        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var resolvedURL: URL?
                if let data = item as? Data {
                    resolvedURL = URL(dataRepresentation: data, relativeTo: nil)
                } else if let url = item as? URL {
                    resolvedURL = url
                }
                Task { @MainActor in
                    if let url = resolvedURL, let saved = self.saveImageFromFileURL(url) {
                        completion(.success(saved))
                    } else {
                        completion(.failure(CoverError.invalidImageData))
                    }
                }
            }
            return true
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                Task { @MainActor in
                    if let data, let img = NSImage(data: data), let saved = self.saveImage(img) {
                        completion(.success(saved))
                    } else {
                        completion(.failure(CoverError.invalidImageData))
                    }
                }
            }
            return true
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                var urlStr: String?
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    urlStr = url.absoluteString
                } else if let url = item as? URL {
                    urlStr = url.absoluteString
                }
                Task { @MainActor in
                    if let urlStr {
                        do {
                            let saved = try await self.downloadAndSaveImage(from: urlStr)
                            completion(.success(saved))
                        } catch {
                            completion(.failure(error))
                        }
                    } else {
                        completion(.failure(CoverError.invalidURL))
                    }
                }
            }
            return true
        }

        return false
    }

    private func rasterizedBitmap(from image: NSImage, maxPixelDimension: CGFloat) -> NSImage {
        var proposedRect = NSRect(origin: .zero, size: image.size)
        guard let cgImg = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            return image
        }

        let srcW = CGFloat(cgImg.width)
        let srcH = CGFloat(cgImg.height)
        guard srcW > 0, srcH > 0 else { return image }

        let maxSide = max(srcW, srcH)
        let scale = maxSide > maxPixelDimension ? (maxPixelDimension / maxSide) : 1.0
        let dstW = max(1, Int(round(srcW * scale)))
        let dstH = max(1, Int(round(srcH * scale)))

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: dstW,
            height: dstH,
            bitsPerComponent: 8,
            bytesPerRow: dstW * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return image
        }

        ctx.interpolationQuality = .high
        ctx.draw(cgImg, in: CGRect(x: 0, y: 0, width: dstW, height: dstH))
        guard let decodedCG = ctx.makeImage() else { return image }

        return NSImage(
            cgImage: decodedCG,
            size: NSSize(width: CGFloat(dstW) / 2.0, height: CGFloat(dstH) / 2.0)
        )
    }
}

enum CoverError: LocalizedError {
    case invalidURL
    case downloadFailed
    case invalidImageData
    case saveFailed

    func message(in lang: AppLanguage) -> String {
        switch self {
        case .invalidURL:
            return lang.tr("请输入有效的网络图片链接", "Please enter a valid image URL")
        case .downloadFailed:
            return lang.tr("无法下载该图片，请检查网络或尝试直接粘贴图片", "Failed to download image; please check the URL or paste directly")
        case .invalidImageData:
            return lang.tr("未能识别为有效图片格式", "Unrecognized image format")
        case .saveFailed:
            return lang.tr("保存封面图片失败", "Failed to save cover image")
        }
    }

    var errorDescription: String? {
        let raw = UserDefaults.standard.string(forKey: "shelf.language") ?? "zh"
        let lang = AppLanguage(rawValue: raw) ?? .zh
        return message(in: lang)
    }
}
