import AppKit
import Foundation
import ImageIO
import IOSurface
import UniformTypeIdentifiers

enum CoverImageIO {
    static let thumbnailPixels = 440
    static let previewPixels = 560
    static let originalPixels = 960

    static func decode(file: URL, maxPixel: Int) -> CGImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        let source = CGImageSourceCreateWithURL(file as CFURL, options)
        return source.flatMap { decode(source: $0, maxPixel: maxPixel) }
    }

    /// Thumbnail files produced by Shelf already have the display size and orientation.
    static func decodeStoredThumbnail(file: URL) -> CGImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(file as CFURL, options) else { return nil }
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int,
           max(width, height) <= thumbnailPixels,
           (properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1 {
            let decodeOptions = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
            if let image = CGImageSourceCreateImageAtIndex(source, 0, decodeOptions) { return image }
        }
        return decode(source: source, maxPixel: thumbnailPixels)
    }

    static func decode(data: Data, maxPixel: Int) -> CGImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        let source = CGImageSourceCreateWithData(data as CFData, options)
        return source.flatMap { decode(source: $0, maxPixel: maxPixel) }
    }

    private static func decode(source: CGImageSource, maxPixel: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func resized(_ image: CGImage, maxPixel: Int) -> CGImage? {
        let scale = min(1, CGFloat(maxPixel) / CGFloat(max(image.width, image.height)))
        if scale == 1 { return image }
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// A tiny, filtered texture gives the detail header soft color without a live blur pass.
    static func previewBackdrop(_ image: CGImage) -> CGImage? {
        let width = 12, height = 9
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let scale = max(CGFloat(width) / CGFloat(image.width), CGFloat(height) / CGFloat(image.height))
        let w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: (CGFloat(width) - w) / 2, y: (CGFloat(height) - h) / 2, width: w, height: h))
        return context.makeImage()
    }

    /// Core Animation can share this backing directly with the window server.
    static func displaySurface(_ image: CGImage) -> IOSurfaceRef? {
        let width = image.width, height = image.height
        let stride = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, width * 4)
        let properties: [CFString: Any] = [
            kIOSurfaceWidth: width, kIOSurfaceHeight: height, kIOSurfaceBytesPerElement: 4,
            kIOSurfaceBytesPerRow: stride, kIOSurfaceAllocSize: stride * height,
            kIOSurfacePixelFormat: 0x42475241 // 'BGRA'
        ]
        guard let surface = IOSurfaceCreate(properties as CFDictionary),
              IOSurfaceLock(surface, [], nil) == kIOReturnSuccess else { return nil }
        defer { IOSurfaceUnlock(surface, [], nil) }
        guard let context = CGContext(data: IOSurfaceGetBaseAddress(surface), width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: stride, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            context.setBlendMode(.copy)
        default:
            context.setFillColor(gray: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.flush()
        return surface
    }

    static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        let options = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// ImageIO handles the usual raster formats. AppKit also accepts vector images, including pasted PDF.
    static func decodeForImport(file: URL) -> CGImage? {
        let accessing = file.startAccessingSecurityScopedResource()
        defer { if accessing { file.stopAccessingSecurityScopedResource() } }
        return decode(file: file, maxPixel: originalPixels)
            ?? NSImage(contentsOf: file).flatMap(rasterizeForImport)
    }

    static func decodeForImport(data: Data) -> CGImage? {
        decode(data: data, maxPixel: originalPixels)
            ?? NSImage(data: data).flatMap(rasterizeForImport)
    }

    private static func rasterizeForImport(_ image: NSImage) -> CGImage? {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        return resized(cg, maxPixel: originalPixels)
    }
}
