import AppKit
import CoreGraphics
import Foundation

func renderIcon(size: Int) -> Data? {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    guard let ctx = NSGraphicsContext.current?.cgContext else { return nil }

    let s = CGFloat(size)
    let pad = s * 0.095
    let rect = CGRect(x: pad, y: pad, width: s - pad * 2, height: s - pad * 2)
    let radius = rect.width * 0.225

    // macOS Big Sur+ squircle-like rounded rect
    let bgPath = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    bgPath.addClip()

    // Rich deep midnight gradient background
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bgColors = [
        CGColor(red: 0.16, green: 0.21, blue: 0.40, alpha: 1.0),
        CGColor(red: 0.09, green: 0.11, blue: 0.22, alpha: 1.0),
        CGColor(red: 0.05, green: 0.06, blue: 0.12, alpha: 1.0)
    ] as CFArray
    if let grad = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0.0, 0.55, 1.0]) {
        ctx.drawLinearGradient(
            grad,
            start: CGPoint(x: rect.minX, y: rect.maxY),
            end: CGPoint(x: rect.maxX, y: rect.minY),
            options: []
        )
    }

    // Subtle ambient top glow
    let glowColors = [
        CGColor(red: 0.36, green: 0.56, blue: 0.98, alpha: 0.35),
        CGColor(red: 0.36, green: 0.56, blue: 0.98, alpha: 0.0)
    ] as CFArray
    if let radial = CGGradient(colorsSpace: colorSpace, colors: glowColors, locations: [0.0, 1.0]) {
        ctx.drawRadialGradient(
            radial,
            startCenter: CGPoint(x: s * 0.5, y: s * 0.72),
            startRadius: 0,
            endCenter: CGPoint(x: s * 0.5, y: s * 0.72),
            endRadius: s * 0.46,
            options: []
        )
    }

    // Helper to draw a tilted 2:3 poster card
    func drawPosterCard(centerX: CGFloat, centerY: CGFloat, width: CGFloat, angleDeg: CGFloat, topColor: CGColor, bottomColor: CGColor) {
        let height = width * 1.46
        ctx.saveGState()
        ctx.translateBy(x: centerX, y: centerY)
        ctx.rotate(by: angleDeg * .pi / 180.0)
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.022), blur: s * 0.045, color: CGColor(gray: 0, alpha: 0.52))

        let cardRect = CGRect(x: -width / 2, y: -height / 2, width: width, height: height)
        let cardRadius = width * 0.13
        let cardPath = CGPath(roundedRect: cardRect, cornerWidth: cardRadius, cornerHeight: cardRadius, transform: nil)
        ctx.addPath(cardPath)
        ctx.fillPath()

        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.addPath(cardPath)
        ctx.clip()

        if let cGrad = CGGradient(colorsSpace: colorSpace, colors: [topColor, bottomColor] as CFArray, locations: [0.0, 1.0]) {
            ctx.drawLinearGradient(
                cGrad,
                start: CGPoint(x: cardRect.minX, y: cardRect.maxY),
                end: CGPoint(x: cardRect.maxX, y: cardRect.minY),
                options: []
            )
        }

        // Subtle inner border
        ctx.resetClip()
        ctx.addPath(cardPath)
        ctx.setStrokeColor(CGColor(gray: 1.0, alpha: 0.30))
        ctx.setLineWidth(max(1.0, s * 0.004))
        ctx.strokePath()
        ctx.restoreGState()
    }

    // Left poster (warm novel amber)
    drawPosterCard(
        centerX: s * 0.35,
        centerY: s * 0.50,
        width: s * 0.25,
        angleDeg: 11,
        topColor: CGColor(red: 0.96, green: 0.62, blue: 0.26, alpha: 1.0),
        bottomColor: CGColor(red: 0.68, green: 0.29, blue: 0.14, alpha: 1.0)
    )

    // Right poster (cinema rose)
    drawPosterCard(
        centerX: s * 0.65,
        centerY: s * 0.50,
        width: s * 0.25,
        angleDeg: -11,
        topColor: CGColor(red: 0.94, green: 0.36, blue: 0.54, alpha: 1.0),
        bottomColor: CGColor(red: 0.58, green: 0.15, blue: 0.34, alpha: 1.0)
    )

    // Center hero poster (game sapphire)
    drawPosterCard(
        centerX: s * 0.50,
        centerY: s * 0.52,
        width: s * 0.29,
        angleDeg: 0,
        topColor: CGColor(red: 0.35, green: 0.65, blue: 1.0, alpha: 1.0),
        bottomColor: CGColor(red: 0.18, green: 0.34, blue: 0.84, alpha: 1.0)
    )

    // Shelf base bar underneath posters
    let shelfRect = CGRect(x: s * 0.23, y: s * 0.22, width: s * 0.54, height: s * 0.032)
    let shelfPath = CGPath(roundedRect: shelfRect, cornerWidth: shelfRect.height / 2, cornerHeight: shelfRect.height / 2, transform: nil)
    ctx.addPath(shelfPath)
    ctx.setFillColor(CGColor(gray: 1.0, alpha: 0.22))
    ctx.fillPath()

    // Outer squircle subtle glass border
    let borderPath = NSBezierPath(roundedRect: rect.insetBy(dx: s * 0.004, dy: s * 0.004), xRadius: radius, yRadius: radius)
    NSColor(white: 1.0, alpha: 0.18).setStroke()
    borderPath.lineWidth = max(1.0, s * 0.008)
    borderPath.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let outDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let specs: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (name, px) in specs {
    if let data = renderIcon(size: px) {
        try data.write(to: outDir.appendingPathComponent(name))
    }
}
print("Generated iconset successfully.")
