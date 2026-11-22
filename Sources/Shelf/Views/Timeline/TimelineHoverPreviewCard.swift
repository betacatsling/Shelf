import SwiftUI

enum TimelineDateFormatter {
    static let ymd: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.calendar = Calendar(identifier: .gregorian)
        df.dateFormat = "yyyy-MM-dd"
        return df
    }()

    static let zhMD: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.calendar = Calendar(identifier: .gregorian)
        df.dateFormat = "M月d日"
        return df
    }()

    static let enMD: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US")
        df.calendar = Calendar(identifier: .gregorian)
        df.dateFormat = "MMM d"
        return df
    }()

    static func spanText(
        start: Date,
        end: Date,
        isOngoing: Bool,
        durationDays: Int,
        language: AppLanguage,
        compact: Bool = false
    ) -> String {
        let fmt: DateFormatter = compact ? (language == .zh ? zhMD : enMD) : ymd
        let startStr = fmt.string(from: start)
        if isOngoing {
            return "\(startStr) – \(language.tr("至今", "Now"))"
        }
        let endStr = fmt.string(from: end)
        if durationDays <= 1 || startStr == endStr {
            return startStr
        }
        return "\(startStr) – \(endStr)"
    }

    static func durationText(days: Int, isOngoing: Bool, language: AppLanguage) -> String {
        if isOngoing {
            return language.tr("第 \(days) 天", "Day \(days)")
        }
        if days <= 1 {
            return language.tr("1 天", "1d")
        }
        return language.tr("\(days) 天", "\(days)d")
    }
}

struct TimelineHoverPreviewCard: View {
    let entry: TimelineEntry
    let anchorRect: CGRect
    let containerSize: CGSize
    let language: AppLanguage

    private let posterWidth: CGFloat = 176
    private let posterHeight: CGFloat = 264
    private let cardPadding: CGFloat = 10
    private let estimatedCardHeight: CGFloat = 342
    private let edgePadding: CGFloat = 16
    private let verticalGap: CGFloat = 10

    private var cardWidth: CGFloat { posterWidth + cardPadding * 2 }

    private var clampedCenter: CGPoint {
        // Anchor horizontally near the card's leading poster (slightly offset right)
        let targetX = anchorRect.minX + min(anchorRect.width * 0.5, 96)
        let halfW = cardWidth / 2
        let minX = halfW + edgePadding
        let maxX = max(minX, containerSize.width - halfW - edgePadding)
        let centerX = min(max(targetX, minX), maxX)

        let halfH = estimatedCardHeight / 2
        let spaceAbove = anchorRect.minY - verticalGap - edgePadding
        let spaceBelow = containerSize.height - anchorRect.maxY - verticalGap - edgePadding

        let preferredY: CGFloat
        if spaceAbove >= estimatedCardHeight || spaceAbove >= spaceBelow {
            preferredY = anchorRect.minY - verticalGap - halfH
        } else {
            preferredY = anchorRect.maxY + verticalGap + halfH
        }

        let minY = halfH + edgePadding
        let maxY = max(minY, containerSize.height - halfH - edgePadding)
        let centerY = min(max(preferredY, minY), maxY)
        return CGPoint(x: centerX, y: centerY)
    }

    var body: some View {
        let poster = entry.poster
        let statusTint = poster.status.tintColor

        CoverPreview(fileName: poster.coverFileName) { artwork in
            VStack(alignment: .leading, spacing: 9) {
                ZStack(alignment: .topTrailing) {
                    CoverArtworkView(
                        title: poster.title,
                        category: poster.category,
                        subtag: poster.subtag,
                        image: artwork?.image,
                        paletteSeed: poster.paletteSeed,
                        language: language,
                        cornerRadius: 11,
                        isHovered: true
                    )
                    .frame(width: posterWidth, height: posterHeight)
                    .shadow(color: .black.opacity(0.38), radius: 14, x: 0, y: 8)

                    // Minimal translucent status dot pill
                    HStack(spacing: 4) {
                        Circle()
                            .fill(statusTint)
                            .frame(width: 6, height: 6)
                        Text(poster.category.statusLabel(for: poster.status, in: language))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 7.5)
                    .padding(.vertical, 3.5)
                    .background(.black.opacity(0.62), in: Capsule())
                    .overlay(
                        Capsule()
                            .strokeBorder(.white.opacity(0.20), lineWidth: 0.6)
                    )
                    .padding(8)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(poster.title)
                            .font(.system(size: 13.5, weight: .bold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Spacer(minLength: 2)

                        if poster.rating > 0 {
                            HStack(spacing: 2) {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(ShelfTheme.starGold)
                                Text("\(poster.rating)")
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    HStack(spacing: 6) {
                        Text(
                            TimelineDateFormatter.spanText(
                                start: entry.startDay,
                                end: entry.endDay,
                                isOngoing: entry.isOngoing,
                                durationDays: entry.durationDays,
                                language: language
                            )
                        )
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                        Spacer(minLength: 2)

                        Text(
                            TimelineDateFormatter.durationText(
                                days: entry.durationDays,
                                isOngoing: entry.isOngoing,
                                language: language
                            )
                        )
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(statusTint)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(statusTint.opacity(0.15), in: Capsule())
                    }
                }
                .padding(.horizontal, 2)
            }
            .padding(cardPadding)
            .frame(width: cardWidth)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .fill(.ultraThickMaterial)
                    if let backdrop = artwork?.backdrop {
                        Image(decorative: backdrop, scale: 1)
                            .resizable()
                            .scaledToFill()
                            .opacity(0.24)
                            .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                    } else {
                        RoundedRectangle(cornerRadius: 17, style: .continuous)
                            .fill(poster.category.accentColor.opacity(0.08))
                    }
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.32), Color.primary.opacity(0.10)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.9
                    )
            )
            .shadow(color: .black.opacity(0.34), radius: 28, x: 0, y: 14)
        }
        .position(clampedCenter)
        .allowsHitTesting(false)
    }
}
