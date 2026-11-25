import SwiftUI

struct TimelineCardView: View {
    static let cardBodyHeight: CGFloat = 60
    static let footrailTopGap: CGFloat = 4.5
    static let footrailHeight: CGFloat = 5.5
    static let totalLaneHeight: CGFloat = cardBodyHeight + footrailTopGap + footrailHeight

    let entry: TimelineEntry
    let showCategoryGlyph: Bool
    let isSelected: Bool
    let hover: TimelineHoverState
    let scrollTracker: TimelineScrollTracker
    let language: AppLanguage
    let coordinateSpaceName: String
    let actions: TimelineActions

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var lastTapAt: Date = .distantPast

    var body: some View {
        let poster = entry.poster
        let isHovered = hover.target?.entry.id == entry.id
        let statusTint = poster.status.tintColor
        let palette = CoverPalette.forSeed(poster.paletteSeed)
        let cornerRadius: CGFloat = 11
        let isWideBar = entry.width >= 300
        let isTrueScale = entry.actualWidth >= entry.width - 5

        VStack(alignment: .leading, spacing: Self.footrailTopGap) {
            CoverPreview(fileName: poster.coverFileName) { artwork in
                ZStack(alignment: .leading) {
                    cardSurface(
                        artwork: artwork,
                        palette: palette,
                        statusTint: statusTint,
                        isTrueScale: isTrueScale,
                        isHovered: isHovered,
                        isSelected: isSelected,
                        cornerRadius: cornerRadius
                    )

                    if isWideBar {
                        TimelineWideCardContent(
                            entry: entry,
                            artwork: artwork,
                            statusTint: statusTint,
                            showCategoryGlyph: showCategoryGlyph,
                            isHovered: isHovered,
                            scrollTracker: scrollTracker,
                            language: language
                        )
                    } else {
                        cardCoreCluster(
                            artwork: artwork,
                            statusTint: statusTint,
                            isHovered: isHovered,
                            maxWidth: entry.width
                        )
                    }
                }
                .frame(width: entry.width, height: Self.cardBodyHeight, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            borderStyle(
                                statusTint: statusTint,
                                isSelected: isSelected,
                                isHovered: isHovered
                            ),
                            lineWidth: isSelected ? 1.8 : (isHovered ? 1.05 : 0.75)
                        )
                )
                .shadow(
                    color: shadowColor(isSelected: isSelected, isHovered: isHovered),
                    radius: isHovered ? 12 : (isSelected ? 9 : 4.5),
                    x: 0,
                    y: isHovered ? 5 : (isSelected ? 3 : 1.75)
                )
                .offset(y: isHovered && !reduceMotion ? -2.0 : 0)
                .animation(reduceMotion ? nil : ShelfMotion.micro, value: isHovered)
                .animation(reduceMotion ? nil : ShelfMotion.micro, value: isSelected)
            }

            precisionFootrail(
                statusTint: statusTint,
                isTrueScale: isTrueScale,
                isHovered: isHovered,
                isSelected: isSelected
            )
        }
        .frame(width: entry.width, height: Self.totalLaneHeight, alignment: .topLeading)
        .background {
            GeometryReader { geo in
                Color.clear
                    .onChange(of: isHovered ? geo.frame(in: .named(coordinateSpaceName)) : nil) { old, new in
                        if let old, let new, old != new { hover.leave(entry.id) }
                    }
                    .onHover { hovering in
                        if hovering {
                            hover.enter(entry, rect: geo.frame(in: .named(coordinateSpaceName)))
                        } else {
                            hover.leave(entry.id)
                        }
                    }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            hover.leave(entry.id)
            let now = Date()
            if now.timeIntervalSince(lastTapAt) <= 0.32 {
                lastTapAt = .distantPast
                actions.onEnsureSelectItem(poster.id)
                actions.onDoubleClickEdit(poster.id)
            } else {
                lastTapAt = now
                actions.onSelectItem(poster.id)
            }
        }
        .contextMenu {
            cardContextMenu(poster: poster)
        }
    }

    // MARK: - Card Surface

    private func cardSurface(
        artwork: CoverManager.Artwork?,
        palette: CoverPalette,
        statusTint: Color,
        isTrueScale: Bool,
        isHovered: Bool,
        isSelected: Bool,
        cornerRadius: CGFloat
    ) -> some View {
        let isDark = colorScheme == .dark
        let auraWidth = min(entry.width, 156)

        return ZStack(alignment: .leading) {
            // Crisp adaptive elevated card base
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    isDark
                        ? Color(nsColor: .controlBackgroundColor)
                        : Color(nsColor: .controlBackgroundColor).opacity(0.96)
                )

            // Delicate top-lit specular sheen in dark mode for macOS depth
            if isDark {
                LinearGradient(
                    colors: [
                        Color.white.opacity(isHovered ? 0.075 : 0.045),
                        Color.clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }

            // Localized ambient artwork aura behind the poster only (never stretched soup)
            Group {
                if let backdrop = artwork?.backdrop {
                    Image(decorative: backdrop, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .frame(width: auraWidth, height: Self.cardBodyHeight)
                        .clipped()
                        .opacity(isDark ? (isHovered ? 0.42 : 0.30) : (isHovered ? 0.22 : 0.14))
                } else {
                    LinearGradient(
                        colors: [
                            palette.top.swiftUIColor.opacity(isDark ? 0.34 : 0.16),
                            palette.bottom.swiftUIColor.opacity(isDark ? 0.16 : 0.07)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .frame(width: auraWidth, height: Self.cardBodyHeight)
                }
            }
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black.opacity(0.55), location: 0.48),
                        .init(color: .clear, location: 1.0)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )

            // Subtle status-tinted wash across extended true-scale ribbons
            if isTrueScale {
                LinearGradient(
                    colors: [
                        statusTint.opacity(isDark ? 0.04 : 0.03),
                        statusTint.opacity(isDark ? (entry.isOngoing ? 0.14 : 0.07) : (entry.isOngoing ? 0.09 : 0.045))
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }

            if isSelected {
                Color.accentColor.opacity(isDark ? 0.09 : 0.06)
            }
        }
    }

    private func borderStyle(statusTint: Color, isSelected: Bool, isHovered: Bool) -> AnyShapeStyle {
        if isSelected {
            return AnyShapeStyle(Color.accentColor)
        }
        if isHovered {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        statusTint.opacity(colorScheme == .dark ? 0.65 : 0.55),
                        Color.primary.opacity(colorScheme == .dark ? 0.20 : 0.16)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
        if colorScheme == .dark {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [Color.white.opacity(0.16), Color.white.opacity(0.06)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        } else {
            return AnyShapeStyle(Color.black.opacity(0.115))
        }
    }

    private func shadowColor(isSelected: Bool, isHovered: Bool) -> Color {
        if colorScheme == .dark {
            if isSelected { return Color.accentColor.opacity(0.24) }
            return .black.opacity(isHovered ? 0.38 : 0.22)
        } else {
            if isSelected { return Color.accentColor.opacity(0.18) }
            return .black.opacity(isHovered ? 0.13 : 0.065)
        }
    }

    // MARK: - Compact Card Core Content

    private func cardCoreCluster(
        artwork: CoverManager.Artwork?,
        statusTint: Color,
        isHovered: Bool,
        maxWidth: CGFloat
    ) -> some View {
        let poster = entry.poster

        return HStack(spacing: 10) {
            TimelineMiniPoster(
                image: artwork?.image,
                category: poster.category,
                paletteSeed: poster.paletteSeed,
                width: 34,
                height: 50,
                cornerRadius: 6
            )
            .scaleEffect(isHovered && !reduceMotion ? 1.035 : 1.0)
            .shadow(
                color: .black.opacity(isHovered ? 0.36 : 0.20),
                radius: isHovered ? 6 : 3,
                x: 0,
                y: isHovered ? 2.5 : 1.5
            )
            .animation(reduceMotion ? nil : ShelfMotion.micro, value: isHovered)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(poster.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer(minLength: 2)

                    if poster.rating > 0 {
                        HStack(spacing: 1.5) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 8.5))
                                .foregroundStyle(ShelfTheme.starGold)
                            Text("\(poster.rating)")
                                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                        .fixedSize()
                    }
                }

                HStack(spacing: 5) {
                    TimelineStatusDot(color: statusTint, isOngoing: entry.isOngoing)

                    Text(
                        TimelineDateFormatter.spanText(
                            start: entry.startDay,
                            end: entry.endDay,
                            isOngoing: entry.isOngoing,
                            durationDays: entry.durationDays,
                            language: language,
                            compact: true
                        )
                    )
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                    if maxWidth >= 224 {
                        Text(
                            TimelineDateFormatter.durationText(
                                days: entry.durationDays,
                                isOngoing: entry.isOngoing,
                                language: language
                            )
                        )
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(statusTint)
                        .padding(.horizontal, 5.5)
                        .padding(.vertical, 1)
                        .background(statusTint.opacity(0.13), in: Capsule())
                        .fixedSize()
                    }

                    Spacer(minLength: 0)

                    if showCategoryGlyph {
                        Image(systemName: poster.category.systemImage)
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(poster.category.accentColor.opacity(0.75))
                    }
                }
            }
        }
        .padding(.leading, 5)
        .padding(.trailing, 10)
        .frame(width: maxWidth, height: Self.cardBodyHeight, alignment: .leading)
    }

    // MARK: - Precision True-Duration Footrail

    private func precisionFootrail(
        statusTint: Color,
        isTrueScale: Bool,
        isHovered: Bool,
        isSelected: Bool
    ) -> some View {
        let isDark = colorScheme == .dark
        let clampedSpan = min(max(entry.actualWidth, 5.5), entry.width)
        let isPinpoint = entry.actualWidth < 11

        return ZStack(alignment: .leading) {
            // Subtle full-card alignment rail when card expanded past true duration
            if !isTrueScale {
                Capsule()
                    .fill(Color.primary.opacity(isDark ? 0.09 : 0.075))
                    .frame(width: entry.width, height: 1.5)
            }

            if isPinpoint {
                // Single-day / milestone precision beacon right at exact startDay
                Circle()
                    .fill(statusTint)
                    .frame(width: 5.5, height: 5.5)
                    .shadow(color: statusTint.opacity(isHovered || isSelected ? 0.75 : 0.35), radius: isHovered ? 4 : 2)
            } else {
                // Exact start -> end proportional duration bar
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                statusTint.opacity(isHovered || isSelected ? 1.0 : 0.88),
                                statusTint.opacity(entry.isOngoing ? 1.0 : (isHovered ? 0.85 : 0.62))
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: clampedSpan, height: isHovered || isSelected ? 3.5 : 3.0)
                    .shadow(
                        color: statusTint.opacity(isHovered || entry.isOngoing ? 0.45 : 0.14),
                        radius: isHovered ? 4 : 2
                    )

                if entry.isOngoing {
                    Circle()
                        .fill(statusTint)
                        .frame(width: 5.5, height: 5.5)
                        .overlay(
                            Circle()
                                .strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1)
                        )
                        .shadow(color: statusTint.opacity(0.75), radius: 3.5)
                        .offset(x: max(0, clampedSpan - 5.5))
                }
            }
        }
        .frame(width: entry.width, height: Self.footrailHeight, alignment: .leading)
        .animation(reduceMotion ? nil : ShelfMotion.micro, value: isHovered)
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func cardContextMenu(poster: LibraryPoster) -> some View {
        Menu(language.tr("修改状态", "Change Status")) {
            ForEach(TrackingStatus.filterOrder) { st in
                Button {
                    actions.onChangeStatus(poster.id, st)
                } label: {
                    if poster.status == st {
                        Label(poster.category.statusLabel(for: st, in: language), systemImage: "checkmark")
                    } else {
                        Text(poster.category.statusLabel(for: st, in: language))
                    }
                }
            }
        }

        Menu(language.tr("快速评分", "Rating")) {
            Button(language.tr("清除评分", "Clear Rating")) {
                actions.onChangeRating(poster.id, 0)
            }
            Divider()
            ForEach((1...5).reversed(), id: \.self) { stars in
                Button {
                    actions.onChangeRating(poster.id, stars)
                } label: {
                    let starsText = String(repeating: "★", count: stars)
                    if poster.rating == stars {
                        Label(starsText, systemImage: "checkmark")
                    } else {
                        Text(starsText)
                    }
                }
            }
        }

        Divider()

        Button {
            actions.onRequestEditTags(poster.id)
        } label: {
            Label(language.tr("设置标签…", "Edit Tags…"), systemImage: "tag")
        }

        Button {
            actions.onRequestReplaceCover(poster.id)
        } label: {
            Label(language.tr("更换封面…", "Change Cover…"), systemImage: "photo")
        }

        Button {
            actions.onDoubleClickEdit(poster.id)
        } label: {
            Label(language.tr("编辑作品信息…", "Edit Item…"), systemImage: "pencil")
        }

        Divider()

        Button {
            actions.onClearDates(poster.id)
        } label: {
            Label(language.tr("清除时间线日期", "Clear Timeline Dates"), systemImage: "calendar.badge.minus")
        }

        Button(role: .destructive) {
            actions.onDeleteItem(poster.id)
        } label: {
            Label(language.tr("删除作品", "Delete Item"), systemImage: "trash")
        }
    }
}

// MARK: - Wide Card Sticky Content (Only Subscribes to Scroll Tracker for Wide Bars)

private struct TimelineWideCardContent: View {
    let entry: TimelineEntry
    let artwork: CoverManager.Artwork?
    let statusTint: Color
    let showCategoryGlyph: Bool
    let isHovered: Bool
    let scrollTracker: TimelineScrollTracker
    let language: AppLanguage

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let poster = entry.poster
        let trailingReserve: CGFloat = entry.isOngoing ? 88 : 68
        let clusterWidth: CGFloat = min(256, max(190, entry.width - trailingReserve))
        let maxStickyOffset = max(0, entry.width - clusterWidth - trailingReserve)
        let stickyOffset = max(0, min(scrollTracker.offsetX + 14 - entry.x, maxStickyOffset))

        ZStack(alignment: .leading) {
            // Sticky leading poster + title + date cluster
            HStack(spacing: 10) {
                TimelineMiniPoster(
                    image: artwork?.image,
                    category: poster.category,
                    paletteSeed: poster.paletteSeed,
                    width: 34,
                    height: 50,
                    cornerRadius: 6
                )
                .scaleEffect(isHovered && !reduceMotion ? 1.035 : 1.0)
                .shadow(
                    color: .black.opacity(isHovered ? 0.36 : 0.20),
                    radius: isHovered ? 6 : 3,
                    x: 0,
                    y: isHovered ? 2.5 : 1.5
                )
                .animation(reduceMotion ? nil : ShelfMotion.micro, value: isHovered)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(poster.title)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        if poster.rating > 0 {
                            HStack(spacing: 1.5) {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 8.5))
                                    .foregroundStyle(ShelfTheme.starGold)
                                Text("\(poster.rating)")
                                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                            .fixedSize()
                        }
                    }

                    HStack(spacing: 5) {
                        TimelineStatusDot(color: statusTint, isOngoing: entry.isOngoing)

                        Text(
                            TimelineDateFormatter.spanText(
                                start: entry.startDay,
                                end: entry.endDay,
                                isOngoing: entry.isOngoing,
                                durationDays: entry.durationDays,
                                language: language,
                                compact: true
                            )
                        )
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                        Text(
                            TimelineDateFormatter.durationText(
                                days: entry.durationDays,
                                isOngoing: entry.isOngoing,
                                language: language
                            )
                        )
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(statusTint)
                        .padding(.horizontal, 5.5)
                        .padding(.vertical, 1)
                        .background(statusTint.opacity(0.13), in: Capsule())
                        .fixedSize()

                        if showCategoryGlyph {
                            Image(systemName: poster.category.systemImage)
                                .font(.system(size: 9.5, weight: .medium))
                                .foregroundStyle(poster.category.accentColor.opacity(0.75))
                        }
                    }
                }
            }
            .padding(.leading, 5)
            .padding(.trailing, 8)
            .frame(width: clusterWidth, height: TimelineCardView.cardBodyHeight, alignment: .leading)
            .offset(x: stickyOffset)

            // Trailing end-cap indicator (live ongoing pill or quiet finish date)
            HStack {
                Spacer(minLength: 0)
                if entry.isOngoing {
                    HStack(spacing: 4.5) {
                        TimelineStatusDot(color: statusTint, isOngoing: true)
                        Text(language.tr("进行中", "Active"))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(statusTint)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3.5)
                    .background(statusTint.opacity(0.13), in: Capsule())
                    .padding(.trailing, 10)
                } else {
                    Text(
                        TimelineDateFormatter.shortDayText(entry.endDay, language: language)
                    )
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .padding(.trailing, 11)
                }
            }
            .frame(width: entry.width, height: TimelineCardView.cardBodyHeight)
        }
    }
}

// MARK: - Shared Card Micro-Components

struct TimelineStatusDot: View {
    let color: Color
    let isOngoing: Bool

    var body: some View {
        ZStack {
            if isOngoing {
                Circle()
                    .fill(color.opacity(0.28))
                    .frame(width: 10, height: 10)
            }
            Circle()
                .fill(color)
                .frame(width: 5.5, height: 5.5)
        }
        .frame(width: isOngoing ? 10 : 6, height: 10)
    }
}

struct TimelineMiniPoster: View {
    let image: CGImage?
    let category: MediaCategory
    let paletteSeed: Int
    let width: CGFloat
    let height: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        let palette = CoverPalette.forSeed(paletteSeed)

        ZStack {
            if let image {
                Image(decorative: image, scale: 2)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(
                    colors: [palette.top.swiftUIColor, palette.bottom.swiftUIColor],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: category.systemImage)
                    .font(.system(size: width * 0.36, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.86))
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.32), Color.white.opacity(0.10)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.65
                )
        )
    }
}
