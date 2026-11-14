import AppKit

struct PosterPlaceholder: Hashable, Sendable {
    let title: String
    let category: MediaCategory
    let subtag: String
    let paletteSeed: Int
    let language: AppLanguage

    private static let palettes: [([CGFloat], [CGFloat], [CGFloat], [CGFloat])] = [
        ([0.16, 0.22, 0.45, 1], [0.10, 0.13, 0.28, 1], [0.06, 0.07, 0.15, 1], [0.42, 0.58, 0.98, 1]),
        ([0.12, 0.34, 0.30, 1], [0.08, 0.21, 0.20, 1], [0.04, 0.11, 0.12, 1], [0.32, 0.85, 0.68, 1]),
        ([0.44, 0.15, 0.24, 1], [0.26, 0.09, 0.16, 1], [0.13, 0.05, 0.09, 1], [0.96, 0.42, 0.54, 1]),
        ([0.46, 0.27, 0.14, 1], [0.28, 0.16, 0.09, 1], [0.14, 0.08, 0.05, 1], [0.96, 0.68, 0.32, 1]),
        ([0.32, 0.18, 0.44, 1], [0.19, 0.11, 0.29, 1], [0.09, 0.06, 0.16, 1], [0.75, 0.48, 0.98, 1]),
        ([0.13, 0.31, 0.42, 1], [0.08, 0.19, 0.28, 1], [0.05, 0.10, 0.16, 1], [0.35, 0.76, 0.96, 1]),
        ([0.28, 0.25, 0.22, 1], [0.16, 0.15, 0.14, 1], [0.08, 0.08, 0.08, 1], [0.88, 0.74, 0.50, 1]),
        ([0.48, 0.21, 0.19, 1], [0.29, 0.12, 0.14, 1], [0.14, 0.07, 0.09, 1], [0.98, 0.55, 0.38, 1])
    ]

    func draw() -> CGImage? {
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

        let p = Self.palettes[Int(paletteSeed.magnitude % UInt(Self.palettes.count))]

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
        defer { NSGraphicsContext.restoreGraphicsState() }

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

        return ctx.makeImage()
    }
}
