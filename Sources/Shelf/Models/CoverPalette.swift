import AppKit
import CoreGraphics
import SwiftUI

struct RGBColor: Equatable, Hashable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    var swiftUIColor: Color {
        Color(red: red, green: green, blue: blue)
    }

    func nsColor(alpha: CGFloat = 1.0) -> NSColor {
        NSColor(srgbRed: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: alpha)
    }

    func cgComponents(alpha: CGFloat = 1.0) -> [CGFloat] {
        [CGFloat(red), CGFloat(green), CGFloat(blue), alpha]
    }
}

/// Shared 8-theme editorial palette used by both SwiftUI `CoverArtworkView` and CoreGraphics `PosterPlaceholder`.
struct CoverPalette: Equatable, Hashable, Sendable {
    let top: RGBColor
    let middle: RGBColor
    let bottom: RGBColor
    let glow: RGBColor

    static let all: [CoverPalette] = [
        CoverPalette(
            top: RGBColor(red: 0.16, green: 0.22, blue: 0.45),
            middle: RGBColor(red: 0.10, green: 0.13, blue: 0.28),
            bottom: RGBColor(red: 0.06, green: 0.07, blue: 0.15),
            glow: RGBColor(red: 0.42, green: 0.58, blue: 0.98)
        ),
        CoverPalette(
            top: RGBColor(red: 0.12, green: 0.34, blue: 0.30),
            middle: RGBColor(red: 0.08, green: 0.21, blue: 0.20),
            bottom: RGBColor(red: 0.04, green: 0.11, blue: 0.12),
            glow: RGBColor(red: 0.32, green: 0.85, blue: 0.68)
        ),
        CoverPalette(
            top: RGBColor(red: 0.44, green: 0.15, blue: 0.24),
            middle: RGBColor(red: 0.26, green: 0.09, blue: 0.16),
            bottom: RGBColor(red: 0.13, green: 0.05, blue: 0.09),
            glow: RGBColor(red: 0.96, green: 0.42, blue: 0.54)
        ),
        CoverPalette(
            top: RGBColor(red: 0.46, green: 0.27, blue: 0.14),
            middle: RGBColor(red: 0.28, green: 0.16, blue: 0.09),
            bottom: RGBColor(red: 0.14, green: 0.08, blue: 0.05),
            glow: RGBColor(red: 0.96, green: 0.68, blue: 0.32)
        ),
        CoverPalette(
            top: RGBColor(red: 0.32, green: 0.18, blue: 0.44),
            middle: RGBColor(red: 0.19, green: 0.11, blue: 0.29),
            bottom: RGBColor(red: 0.09, green: 0.06, blue: 0.16),
            glow: RGBColor(red: 0.75, green: 0.48, blue: 0.98)
        ),
        CoverPalette(
            top: RGBColor(red: 0.13, green: 0.31, blue: 0.42),
            middle: RGBColor(red: 0.08, green: 0.19, blue: 0.28),
            bottom: RGBColor(red: 0.05, green: 0.10, blue: 0.16),
            glow: RGBColor(red: 0.35, green: 0.76, blue: 0.96)
        ),
        CoverPalette(
            top: RGBColor(red: 0.28, green: 0.25, blue: 0.22),
            middle: RGBColor(red: 0.16, green: 0.15, blue: 0.14),
            bottom: RGBColor(red: 0.08, green: 0.08, blue: 0.08),
            glow: RGBColor(red: 0.88, green: 0.74, blue: 0.50)
        ),
        CoverPalette(
            top: RGBColor(red: 0.48, green: 0.21, blue: 0.19),
            middle: RGBColor(red: 0.29, green: 0.12, blue: 0.14),
            bottom: RGBColor(red: 0.14, green: 0.07, blue: 0.09),
            glow: RGBColor(red: 0.98, green: 0.55, blue: 0.38)
        )
    ]

    static func forSeed(_ seed: Int) -> CoverPalette {
        all[Int(seed.magnitude % UInt(all.count))]
    }
}
