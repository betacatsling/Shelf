import SwiftUI

enum TimelineDateFormatter {
    static let ymd: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.calendar = Calendar(identifier: .gregorian)
        df.dateFormat = "yyyy-MM-dd"
        return df
    }()

    static let compactMD: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.calendar = Calendar(identifier: .gregorian)
        df.dateFormat = "M/d"
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
        let startStr = (compact ? compactMD : ymd).string(from: start)
        if isOngoing {
            return "\(startStr) → \(language.tr("进行中", "Ongoing"))"
        }
        let endStr = (compact ? compactMD : ymd).string(from: end)
        if durationDays <= 1 || startStr == endStr {
            return startStr
        }
        return "\(startStr) → \(endStr)"
    }

    static func durationText(days: Int, isOngoing: Bool, language: AppLanguage) -> String {
        if isOngoing {
            return language.tr("已持续 \(days) 天", "\(days)d so far")
        }
        if days <= 1 {
            return language.tr("单日", "1 day")
        }
        return language.tr("共 \(days) 天", "\(days) days")
    }
}

struct TimelineHoverPreviewCard: View {
    let entry: TimelineEntry
    let anchorRect: CGRect
    let containerSize: CGSize
    let language: AppLanguage

    private let cardWidth: CGFloat = 192
    private let posterWidth: CGFloat = 156
    private let posterHeight: CGFloat = 234
    private let estimatedCardHeight: CGFloat = 338
    private let edgePadding: CGFloat = 14
    private let verticalGap: CGFloat = 12

    private var clampedCenter: CGPoint {
        let halfW = cardWidth / 2
        let minX = halfW + edgePadding
        let maxX = max(minX, containerSize.width - halfW - edgePadding)
        let centerX = min(max(anchorRect.midX, minX), maxX)

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
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .topTrailing) {
                    CoverArtworkView(
                        title: poster.title,
                        category: poster.category,
                        subtag: poster.subtag,
                        image: artwork?.image,
                        paletteSeed: poster.paletteSeed,
                        language: language,
                        cornerRadius: 10,
                        isHovered: true
                    )
                    .frame(width: posterWidth, height: posterHeight)
                    .shadow(color: .black.opacity(0.32), radius: 12, x: 0, y: 6)

                    // Status pill badge on cover top-right
                    HStack(spacing: 4) {
                        Circle()
                            .fill(statusTint)
                            .frame(width: 6, height: 6)
                        Text(poster.category.statusLabel(for: poster.status, in: language))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3.5)
                    .background(Color.black.opacity(0.68), in: Capsule())
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.6)
                    )
                    .padding(7)
                }
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 4) {
                    Text(poster.title)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    if let secondary = poster.secondaryTitle {
                        Text(secondary)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    HStack(spacing: 6) {
                        if poster.rating > 0 {
                            StarRatingView(
                                rating: .constant(poster.rating),
                                starSize: 10,
                                spacing: 2,
                                interactive: false
                            )
                        }

                        Spacer(minLength: 0)

                        Text(TimelineDateFormatter.durationText(days: entry.durationDays, isOngoing: entry.isOngoing, language: language))
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(statusTint)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(statusTint.opacity(0.14), in: Capsule())
                    }
                    .padding(.top, 2)

                    HStack(spacing: 4) {
                        Image(systemName: "calendar")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(
                            TimelineDateFormatter.spanText(
                                start: entry.startDay,
                                end: entry.endDay,
                                isOngoing: entry.isOngoing,
                                durationDays: entry.durationDays,
                                language: language
                            )
                        )
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }

                    Text(language.tr("点击查看详情 · 双击编辑", "Click for details · Double-click to edit"))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 1)
                }
            }
            .padding(14)
            .frame(width: cardWidth)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(.regularMaterial)
                    if let backdrop = artwork?.backdrop {
                        Image(decorative: backdrop, scale: 1)
                            .resizable()
                            .scaledToFill()
                            .opacity(0.14)
                            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                    } else {
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .fill(poster.category.accentColor.opacity(0.06))
                    }
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.9)
            )
            .shadow(color: .black.opacity(0.32), radius: 22, x: 0, y: 12)
        }
        .position(clampedCenter)
        .allowsHitTesting(false)
    }
}
