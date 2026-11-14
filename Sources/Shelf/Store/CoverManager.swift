import AppKit
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

@MainActor
final class CoverManager {
    static let shared = CoverManager()

    private let fullCache = NSCache<NSString, NSImage>()
    private let thumbCache = NSCache<NSString, NSImage>()
    let coversDirectory: URL

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let baseDir = appSupport.appendingPathComponent("Shelf", isDirectory: true)
        let coversDir = baseDir.appendingPathComponent("Covers", isDirectory: true)
        self.coversDirectory = coversDir

        try? FileManager.default.createDirectory(at: coversDir, withIntermediateDirectories: true)
        fullCache.countLimit = 150
        thumbCache.countLimit = 400
    }

    /// Returns a pre-decoded 360x540 grid thumbnail so scrolling never decodes JPEG data on the main thread.
    func gridThumbnail(for fileName: String?) -> NSImage? {
        guard let fileName, !fileName.isEmpty else { return nil }
        if let cached = thumbCache.object(forKey: fileName as NSString) {
            return cached
        }
        guard let full = image(for: fileName) else { return nil }
        let thumb = rasterizedBitmap(from: full, maxPixelDimension: 480)
        thumbCache.setObject(thumb, forKey: fileName as NSString)
        return thumb
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
            let thumb = rasterizedBitmap(from: resized, maxPixelDimension: 480)
            thumbCache.setObject(thumb, forKey: newFileName as NSString)

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
        thumbCache.removeObject(forKey: fileName as NSString)
        let url = coversDirectory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: url)
    }

    func chooseLocalImagePanel() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "选择海报封面图片"
        panel.prompt = "设为封面"
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

    /// Forces immediate CGImage decompression into an opaque RGBA bitmap buffer at bounded pixel size.
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

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "请输入有效的网络图片链接"
        case .downloadFailed: return "无法下载该图片，请检查网络或尝试直接粘贴图片"
        case .invalidImageData: return "未能识别为有效图片格式"
        case .saveFailed: return "保存封面图片失败"
        }
    }
}
