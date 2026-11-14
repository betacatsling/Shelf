import AppKit
import SwiftUI

struct CoverArtworkView: View {
    let title: String
    let category: MediaCategory
    let subtag: String
    let coverFileName: String?
    let paletteSeed: Int
    var language: AppLanguage = .zh
    var cornerRadius: CGFloat = 10
    var isHovered: Bool = false
    @State private var loadedCover: (name: String, image: CGImage)?

    private var image: CGImage? {
        guard let name = coverFileName, !name.isEmpty else { return nil }
        if let loadedCover, loadedCover.name == name { return loadedCover.image }
        return CoverManager.shared.cachedArtwork(for: .preview(name))?.image
    }

    private struct Palette {
        let top: Color
        let middle: Color
        let bottom: Color
        let glow: Color
    }

    private static let palettes: [Palette] = [
        Palette(
            top: Color(red: 0.16, green: 0.22, blue: 0.45),
            middle: Color(red: 0.10, green: 0.13, blue: 0.28),
            bottom: Color(red: 0.06, green: 0.07, blue: 0.15),
            glow: Color(red: 0.42, green: 0.58, blue: 0.98)
        ),
        Palette(
            top: Color(red: 0.12, green: 0.34, blue: 0.30),
            middle: Color(red: 0.08, green: 0.21, blue: 0.20),
            bottom: Color(red: 0.04, green: 0.11, blue: 0.12),
            glow: Color(red: 0.32, green: 0.85, blue: 0.68)
        ),
        Palette(
            top: Color(red: 0.44, green: 0.15, blue: 0.24),
            middle: Color(red: 0.26, green: 0.09, blue: 0.16),
            bottom: Color(red: 0.13, green: 0.05, blue: 0.09),
            glow: Color(red: 0.96, green: 0.42, blue: 0.54)
        ),
        Palette(
            top: Color(red: 0.46, green: 0.27, blue: 0.14),
            middle: Color(red: 0.28, green: 0.16, blue: 0.09),
            bottom: Color(red: 0.14, green: 0.08, blue: 0.05),
            glow: Color(red: 0.96, green: 0.68, blue: 0.32)
        ),
        Palette(
            top: Color(red: 0.32, green: 0.18, blue: 0.44),
            middle: Color(red: 0.19, green: 0.11, blue: 0.29),
            bottom: Color(red: 0.09, green: 0.06, blue: 0.16),
            glow: Color(red: 0.75, green: 0.48, blue: 0.98)
        ),
        Palette(
            top: Color(red: 0.13, green: 0.31, blue: 0.42),
            middle: Color(red: 0.08, green: 0.19, blue: 0.28),
            bottom: Color(red: 0.05, green: 0.10, blue: 0.16),
            glow: Color(red: 0.35, green: 0.76, blue: 0.96)
        ),
        Palette(
            top: Color(red: 0.28, green: 0.25, blue: 0.22),
            middle: Color(red: 0.16, green: 0.15, blue: 0.14),
            bottom: Color(red: 0.08, green: 0.08, blue: 0.08),
            glow: Color(red: 0.88, green: 0.74, blue: 0.50)
        ),
        Palette(
            top: Color(red: 0.48, green: 0.21, blue: 0.19),
            middle: Color(red: 0.29, green: 0.12, blue: 0.14),
            bottom: Color(red: 0.14, green: 0.07, blue: 0.09),
            glow: Color(red: 0.98, green: 0.55, blue: 0.38)
        )
    ]

    private var palette: Palette {
        let idx = Int(paletteSeed.magnitude % UInt(Self.palettes.count))
        return Self.palettes[idx]
    }

    var body: some View {
        Color.clear
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .overlay {
                staticCoverLayer
            }
            .overlay {
                if isHovered {
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.16),
                            Color.white.opacity(0.03),
                            Color.clear
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .allowsHitTesting(false)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        Color.white.opacity(isHovered ? 0.34 : 0.16),
                        lineWidth: isHovered ? 1.2 : 0.75
                    )
                    .allowsHitTesting(false)
            )
            .task(id: coverFileName) {
                guard let name = coverFileName, !name.isEmpty else {
                    loadedCover = nil
                    return
                }
                let image = await CoverManager.shared.artwork(for: .preview(name))?.image
                guard !Task.isCancelled else { return }
                loadedCover = image.map { (name, $0) }
            }
    }

    private var staticCoverLayer: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 2)
                    .resizable()
                    .scaledToFill()
            } else {
                editorialBoxArt
            }

            // Subtle physical spine highlight & bottom depth vignette
            LinearGradient(
                colors: [
                    Color.white.opacity(0.07),
                    Color.clear,
                    Color.black.opacity(0.20)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            HStack(spacing: 0) {
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.15),
                        Color.black.opacity(0.10),
                        Color.clear
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: 4)
                Spacer(minLength: 0)
            }
        }
    }

    private var editorialBoxArt: some View {
        let p = palette
        return ZStack {
            LinearGradient(
                colors: [p.top, p.middle, p.bottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            // Ambient soft glow
            RadialGradient(
                colors: [p.glow.opacity(0.32), Color.clear],
                center: .init(x: 0.72, y: 0.28),
                startRadius: 4,
                endRadius: 120
            )

            // Clean center category emblem
            ZStack {
                Circle()
                    .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
                    .frame(width: 96, height: 96)

                Circle()
                    .strokeBorder(p.glow.opacity(0.16), lineWidth: 0.8)
                    .frame(width: 70, height: 70)

                Image(systemName: category.systemImage)
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.white.opacity(0.58), p.glow.opacity(0.38)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
            .offset(y: -14)

            // Editorial top pill & bottom title
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Image(systemName: category.systemImage)
                        .font(.system(size: 9, weight: .semibold))
                    Text(subtag.isEmpty ? category.title(in: language) : MediaCategory.localizedSubtag(subtag, in: language))
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                }
                .foregroundStyle(Color.white.opacity(0.82))
                .padding(.horizontal, 8)
                .padding(.vertical, 3.5)
                .background(Color.white.opacity(0.12), in: Capsule())

                Spacer(minLength: 8)

                Rectangle()
                    .fill(p.glow.opacity(0.65))
                    .frame(width: 22, height: 1.5)
                    .padding(.bottom, 6)

                Text(title.isEmpty ? language.tr("未命名作品", "Untitled") : title)
                    .font(.system(size: 14.5, weight: .bold, design: category == .novel ? .serif : .default))
                    .foregroundStyle(Color.white.opacity(0.95))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .minimumScaleFactor(0.78)
            }
            .padding(13)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}
