import SwiftUI

struct CoverPreview<Content: View>: View {
    let fileName: String?
    @ViewBuilder let content: (CoverManager.Artwork?) -> Content
    @State private var loaded: (name: String, artwork: CoverManager.Artwork?)?

    private var artwork: CoverManager.Artwork? {
        guard let name = fileName, !name.isEmpty else { return nil }
        if let loaded, loaded.name == name { return loaded.artwork }
        return CoverManager.shared.cachedArtwork(for: .preview(name))
    }

    var body: some View {
        content(artwork)
            .task(id: fileName) {
                guard let name = fileName, !name.isEmpty else {
                    loaded = nil
                    return
                }
                let artwork = await CoverManager.shared.artwork(for: .preview(name))
                guard !Task.isCancelled else { return }
                loaded = (name, artwork)
            }
    }
}

struct CoverArtworkView: View {
    let title: String
    let category: MediaCategory
    let subtag: String
    let image: CGImage?
    let paletteSeed: Int
    var language: AppLanguage = .zh
    var cornerRadius: CGFloat = 10
    var isHovered: Bool = false

    private var palette: CoverPalette {
        CoverPalette.forSeed(paletteSeed)
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
        let glow = p.glow.swiftUIColor
        return ZStack {
            LinearGradient(
                colors: [p.top.swiftUIColor, p.middle.swiftUIColor, p.bottom.swiftUIColor],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            // Ambient soft glow
            RadialGradient(
                colors: [glow.opacity(0.32), Color.clear],
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
                    .strokeBorder(glow.opacity(0.16), lineWidth: 0.8)
                    .frame(width: 70, height: 70)

                Image(systemName: category.systemImage)
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.white.opacity(0.58), glow.opacity(0.38)],
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
                    Text(subtag.isEmpty ? category.title(in: language) : MediaCategory.localizedTag(subtag, in: language))
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                }
                .foregroundStyle(Color.white.opacity(0.82))
                .padding(.horizontal, 8)
                .padding(.vertical, 3.5)
                .background(Color.white.opacity(0.12), in: Capsule())

                Spacer(minLength: 8)

                Rectangle()
                    .fill(glow.opacity(0.65))
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
