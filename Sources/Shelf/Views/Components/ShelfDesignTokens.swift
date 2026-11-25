import AppKit
import QuartzCore
import SwiftUI

enum PosterScaleConfig {
    static let storageKey = "shelf.posterScale"
    static let defaultScale: Double = 1.0
    static let minScale: Double = 0.78
    static let maxScale: Double = 1.36
    static let step: Double = 0.08

    static func zoomIn(from current: Double) -> Double {
        min(maxScale, current + step)
    }

    static func zoomOut(from current: Double) -> Double {
        max(minScale, current - step)
    }
}

enum TimelineZoomConfig {
    static let storageKey = "shelf.timelineZoom"
    /// Zoom value in [0.0, 1.0] mapped smoothly on an exponential scale from 1.2 pt/day (year view) to 28 pt/day (week/day view).
    static let minZoom: Double = 0.0
    static let maxZoom: Double = 1.0
    static let defaultZoom: Double = 0.45
    static let step: Double = 0.12

    static let minPointsPerDay: CGFloat = 1.4
    static let maxPointsPerDay: CGFloat = 26.0

    static func pointsPerDay(for zoom: Double) -> CGFloat {
        let clamped = min(max(zoom, minZoom), maxZoom)
        let ratio = maxPointsPerDay / minPointsPerDay
        return minPointsPerDay * CGFloat(pow(Double(ratio), clamped))
    }

    static func zoomIn(from current: Double) -> Double {
        min(maxZoom, current + step)
    }

    static func zoomOut(from current: Double) -> Double {
        max(minZoom, current - step)
    }

    enum Preset: CaseIterable, Identifiable {
        case year
        case quarter
        case month
        case week

        var id: Self { self }

        var zoomValue: Double {
            switch self {
            case .year: return 0.10
            case .quarter: return 0.36
            case .month: return 0.62
            case .week: return 0.90
            }
        }

        func title(in lang: AppLanguage) -> String {
            switch self {
            case .year: return lang.tr("年", "Year")
            case .quarter: return lang.tr("季", "Qtr")
            case .month: return lang.tr("月", "Month")
            case .week: return lang.tr("周", "Week")
            }
        }
    }
}

enum ShelfTheme {
    static let horizontalPadding: CGFloat = 24
    static let bottomBarHeight: CGFloat = 30
    static let posterAspectRatio: CGFloat = 1.5

    static let starGoldRGB = RGBColor(red: 0.96, green: 0.74, blue: 0.20)
    static let starGold: Color = starGoldRGB.swiftUIColor
    static let starGoldNS: NSColor = starGoldRGB.nsColor()

    static let destructiveRed = Color(red: 0.95, green: 0.32, blue: 0.32)
}

enum ShelfMotion {
    /// Snappy spring for hover, press, and subtle micro-feedback.
    static let micro: Animation = .spring(duration: 0.20, bounce: 0.0)
    /// Fluid sliding spring for segmented controls, sidebar selection, and status trays.
    static let control: Animation = .spring(duration: 0.28, bounce: 0.05)
    /// Smooth spring for floating overlays, Quick Find, Tag Picker, and Toast notifications.
    static let panel: Animation = .spring(duration: 0.30, bounce: 0.02)
    /// Quiet deceleration curve for crossfades and content switches.
    static let gentle: Animation = .easeOut(duration: 0.18)

    static func spring(
        keyPath: String,
        stiffness: CGFloat,
        damping: CGFloat,
        mass: CGFloat = 1.0,
        initialVelocity: CGFloat = 0
    ) -> CASpringAnimation {
        let animation = CASpringAnimation(keyPath: keyPath)
        animation.mass = mass
        animation.stiffness = stiffness
        animation.damping = damping
        animation.initialVelocity = initialVelocity
        animation.duration = animation.settlingDuration
        return animation
    }

    static func drawerSlide(keyPath: String = "sublayerTransform") -> CASpringAnimation {
        spring(keyPath: keyPath, stiffness: 360, damping: 36)
    }

    static func cardHover(keyPath: String) -> CASpringAnimation {
        spring(keyPath: keyPath, stiffness: 460, damping: 34)
    }

    static func cardPress(keyPath: String) -> CASpringAnimation {
        spring(keyPath: keyPath, stiffness: 620, damping: 40)
    }

    static func gridReflow(keyPath: String) -> CASpringAnimation {
        spring(keyPath: keyPath, stiffness: 330, damping: 34)
    }
}

/// Subtle adaptive hairline divider that softens chrome transitions in Light & Dark Mode.
struct ShelfHairline: View {
    @Environment(\.colorScheme) private var colorScheme
    var vertical: Bool = false

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.08))
            .frame(width: vertical ? 0.75 : nil, height: vertical ? nil : 0.75)
    }
}

extension TrackingStatus {
    var nsTintColor: NSColor {
        tintRGB.nsColor()
    }
}
