import AppKit

struct PosterPlaceholder: Hashable, Sendable {
    let title: String
    let category: MediaCategory
    let subtag: String
    let paletteSeed: Int
    let language: AppLanguage

    func draw() -> CGImage? {
        let w = 320
        let h = 480
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
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

        let palette = CoverPalette.forSeed(paletteSeed)

        if let grad = CGGradient(
            colorSpace: colorSpace,
            colorComponents: palette.top.cgComponents() + palette.middle.cgComponents() + palette.bottom.cgComponents(),
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
            colorComponents: palette.glow.cgComponents(alpha: 0.30) + palette.glow.cgComponents(alpha: 0.0),
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
        palette.glow.nsColor(alpha: 0.18).setStroke()
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
            : MediaCategory.localizedTag(subtag, in: language)
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
        palette.glow.nsColor(alpha: 0.72).setFill()
        NSBezierPath(rect: barRect).fill()

        return ctx.makeImage()
    }
}
