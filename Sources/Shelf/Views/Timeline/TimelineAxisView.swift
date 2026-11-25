import SwiftUI

// MARK: - Atmospheric Canvas Grid, Alternating Month Rhythm & Future Veil

struct TimelineCanvasBackdrop: View {
    let model: TimelineLayoutModel
    let height: CGFloat

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let isDark = colorScheme == .dark
        let futureWidth = max(0, model.totalWidth - model.todayX)

        ZStack(alignment: .topLeading) {
            // Single Canvas for alternating month fills, current-month wash, future veil & crisp hairlines
            Canvas { context, size in
                let h = size.height

                for tick in model.monthTicks {
                    let rect = CGRect(x: tick.x, y: 0, width: tick.width, height: h)
                    if tick.isCurrentMonth {
                        context.fill(
                            Path(rect),
                            with: .color(.accentColor.opacity(isDark ? 0.045 : 0.036))
                        )
                    } else if tick.month.isMultiple(of: 2) {
                        context.fill(
                            Path(rect),
                            with: .color(.primary.opacity(isDark ? 0.018 : 0.026))
                        )
                    }

                    let lineW: CGFloat = tick.isYearStart ? 1.0 : 0.65
                    let lineOpacity: Double = tick.isYearStart
                        ? (isDark ? 0.16 : 0.17)
                        : (isDark ? 0.055 : 0.075)
                    context.fill(
                        Path(CGRect(x: tick.x, y: 0, width: lineW, height: h)),
                        with: .color(.primary.opacity(lineOpacity))
                    )
                }

                // Subtle future zone veil to the right of Today
                if futureWidth > 1 {
                    let futureRect = CGRect(x: model.todayX, y: 0, width: futureWidth, height: h)
                    context.fill(
                        Path(futureRect),
                        with: .color(.primary.opacity(isDark ? 0.018 : 0.018))
                    )
                }
            }
            .frame(width: model.totalWidth, height: height)

            // Quiet architectural year markers at each Jan 1 boundary
            ForEach(model.monthTicks.filter(\.isYearStart)) { tick in
                Text(String(tick.year))
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .tracking(0.6)
                    .foregroundStyle(Color.primary.opacity(isDark ? 0.25 : 0.28))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Color.primary.opacity(isDark ? 0.045 : 0.05),
                        in: RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                    )
                    .offset(x: tick.x + 8, y: 10)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Today Vertical Guide Line

struct TimelineTodayGuideLine: View {
    let todayX: CGFloat
    let height: CGFloat

    var body: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    stops: [
                        .init(color: Color.accentColor.opacity(0.10), location: 0.0),
                        .init(color: Color.accentColor.opacity(0.40), location: 0.55),
                        .init(color: Color.accentColor.opacity(0.90), location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: 1.5, height: height)
            .shadow(color: Color.accentColor.opacity(0.38), radius: 5, x: 0, y: 0)
            .offset(x: todayX - 0.75)
            .allowsHitTesting(false)
    }
}

// MARK: - Sticky Swimlane Group Header (Pinned to Viewport Leading Edge)

struct TimelineStickyGroupHeader: View {
    let group: TimelineGroup
    let totalWidth: CGFloat
    let scrollTracker: TimelineScrollTracker

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let isDark = colorScheme == .dark
        let accent = group.category?.accentColor ?? Color.accentColor
        let stickyX = min(
            max(16, scrollTracker.offsetX + 16),
            max(16, totalWidth - 170)
        )

        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(accent)
                .frame(width: 3, height: 13)

            if let category = group.category {
                Image(systemName: category.systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accent)
            }

            Text(group.title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.primary.opacity(0.92))

            Text("\(group.entries.count)")
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5.5)
                .padding(.vertical, 1)
                .background(Color.primary.opacity(isDark ? 0.10 : 0.08), in: Capsule())
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .padding(.vertical, 5)
        .background {
            Capsule()
                .fill(.regularMaterial)
                .overlay(
                    Capsule()
                        .fill(accent.opacity(isDark ? 0.08 : 0.06))
                )
        }
        .overlay(
            Capsule()
                .strokeBorder(
                    Color.primary.opacity(isDark ? 0.14 : 0.11),
                    lineWidth: 0.7
                )
        )
        .shadow(
            color: .black.opacity(isDark ? 0.28 : 0.09),
            radius: 6,
            x: 0,
            y: 2
        )
        .fixedSize()
        .offset(x: stickyX)
        .allowsHitTesting(false)
    }
}

// MARK: - Precision Bottom Time Axis Ruler

struct TimelineBottomAxisView: View {
    static let rulerHeight: CGFloat = 56

    let model: TimelineLayoutModel
    let scrollTracker: TimelineScrollTracker
    let language: AppLanguage

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let isDark = colorScheme == .dark
        let clampedTodayX = min(max(model.todayX, 54), max(54, model.totalWidth - 54))

        ZStack(alignment: .topLeading) {
            // Subtle architectural ruler surface distinct from canvas & status bar
            ZStack(alignment: .top) {
                Color(nsColor: .windowBackgroundColor)
                Color.primary.opacity(isDark ? 0.032 : 0.028)
                Rectangle()
                    .fill(Color.primary.opacity(isDark ? 0.14 : 0.12))
                    .frame(height: 0.8)
            }

            // Layout-participating month columns so ScrollViewReader scrolls accurately
            HStack(spacing: 0) {
                Color.clear
                    .frame(width: TimelineLayoutModel.leadingCanvasPadding, height: Self.rulerHeight)

                ForEach(Array(model.monthTicks.enumerated()), id: \.element.id) { index, tick in
                    bottomMonthAxisCell(
                        tick: tick,
                        showYearBadge: tick.isYearStart || index == 0,
                        isDark: isDark
                    )
                    .frame(width: tick.width, height: Self.rulerHeight, alignment: .topLeading)
                    .id(tick.id)
                }
            }

            // Zero-collision Today pill cleanly seated in the ruler's dedicated upper tick strip
            HStack(spacing: 4) {
                Circle()
                    .fill(Color.white)
                    .frame(width: 4, height: 4)
                Text(language.tr("今天", "Today"))
                    .font(.system(size: 9.5, weight: .bold))
                Text(TimelineDateFormatter.shortDayText(model.todayDay, language: language))
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .opacity(0.92)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 7.5)
            .padding(.vertical, 2.5)
            .background(Color.accentColor, in: Capsule())
            .shadow(color: Color.accentColor.opacity(0.38), radius: 5, x: 0, y: 1)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                Capsule()
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.88))
            )
            .fixedSize()
            .position(x: clampedTodayX, y: 12.5)
            .allowsHitTesting(false)

            // Sticky current-year pill pinned to the upper-left of the ruler when year start scrolls off-screen
            TimelineStickyYearBadge(
                model: model,
                scrollTracker: scrollTracker
            )
        }
        .frame(width: model.totalWidth, height: Self.rulerHeight, alignment: .topLeading)
    }

    private func bottomMonthAxisCell(
        tick: TimelineMonthTick,
        showYearBadge: Bool,
        isDark: Bool
    ) -> some View {
        let monthTitle = formattedMonthLabel(tick.month)
        let dayWidth = tick.width / CGFloat(tick.dayCount)
        let showDayTicks = dayWidth >= 5.2
        let showMidMonthTick = !showDayTicks && dayWidth >= 2.2
        let dayStep = dayWidth >= 16 ? 1 : (dayWidth >= 9.5 ? 5 : 10)
        let showInlineYear = tick.width >= 104

        return ZStack(alignment: .topLeading) {
            if tick.isCurrentMonth {
                Color.accentColor.opacity(isDark ? 0.075 : 0.060)
            }

            // Precision tick canvas across top 22pt
            Canvas { context, _ in
                let majorH: CGFloat = tick.isYearStart ? Self.rulerHeight : 12
                let majorW: CGFloat = tick.isYearStart ? 1.1 : 0.7
                let majorAlpha: Double = tick.isYearStart ? 0.28 : 0.15
                context.fill(
                    Path(CGRect(x: 0, y: 0, width: majorW, height: majorH)),
                    with: .color(.primary.opacity(majorAlpha))
                )

                if showDayTicks {
                    if dayWidth >= 11 {
                        for day in 2...tick.dayCount {
                            let x = CGFloat(day - 1) * dayWidth
                            let isLabeled = (day % dayStep == 0) || (dayStep == 1)
                            guard !isLabeled else { continue }
                            context.fill(
                                Path(CGRect(x: x, y: 0, width: 0.5, height: 4)),
                                with: .color(.primary.opacity(0.10))
                            )
                        }
                    }

                    for day in stride(from: dayStep, through: tick.dayCount, by: dayStep) {
                        let x = CGFloat(day - 1) * dayWidth
                        guard x >= 8 && x + 16 <= tick.width else { continue }
                        context.fill(
                            Path(CGRect(x: x, y: 0, width: 0.7, height: 6.5)),
                            with: .color(.primary.opacity(0.20))
                        )
                        let label = Text(String(day))
                            .font(.system(size: 8.5, weight: .medium, design: .rounded).monospacedDigit())
                            .foregroundStyle(.tertiary)
                        context.draw(label, at: CGPoint(x: x + 2.5, y: 6.5), anchor: .topLeading)
                    }
                } else if showMidMonthTick {
                    let midX = CGFloat(14) * dayWidth
                    if midX > 8 && midX < tick.width - 8 {
                        context.fill(
                            Path(CGRect(x: midX, y: 0, width: 0.6, height: 5)),
                            with: .color(.primary.opacity(0.13))
                        )
                    }
                }
            }
            .frame(width: tick.width, height: Self.rulerHeight)

            // Two-tier clean layout when zoomed out: Year badge cleanly in upper band (zero truncation!)
            if showYearBadge && !showInlineYear {
                Text(String(tick.year))
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary.opacity(0.84))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(
                        Color.primary.opacity(isDark ? 0.11 : 0.085),
                        in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                    )
                    .fixedSize()
                    .offset(x: 6, y: 5)
            }

            // Bottom label band (strictly below the 22pt upper zone -> zero collisions)
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 0)

                if showInlineYear {
                    Text(formattedYearMonthLabel(year: tick.year, month: tick.month))
                        .font(.system(size: 11.5, weight: tick.isCurrentMonth ? .bold : .semibold))
                        .foregroundStyle(tick.isCurrentMonth ? Color.accentColor : .primary.opacity(0.86))
                        .lineLimit(1)
                } else if tick.width >= 30 {
                    Text(monthTitle)
                        .font(
                            .system(
                                size: tick.width < 42 ? 10.5 : 11.5,
                                weight: tick.isCurrentMonth ? .bold : (tick.isYearStart ? .semibold : .medium)
                            )
                        )
                        .foregroundStyle(
                            tick.isCurrentMonth
                                ? Color.accentColor
                                : (tick.isYearStart ? .primary.opacity(0.90) : .secondary)
                        )
                        .lineLimit(1)
                }
            }
            .padding(.leading, 7)
            .padding(.bottom, 10)
        }
        .clipped()
    }

    private func formattedMonthLabel(_ month: Int) -> String {
        if language == .zh {
            return "\(month)月"
        }
        let names = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return (1...12).contains(month) ? names[month - 1] : "\(month)"
    }

    private func formattedYearMonthLabel(year: Int, month: Int) -> String {
        if language == .zh {
            return "\(year)年 \(month)月"
        }
        return "\(formattedMonthLabel(month)) \(year)"
    }
}

// MARK: - Sticky Current-Year Pill on Bottom Axis

private struct TimelineStickyYearBadge: View {
    let model: TimelineLayoutModel
    let scrollTracker: TimelineScrollTracker

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let probeX = scrollTracker.offsetX + 14
        if let activeTick = model.tick(atX: probeX) {
            let showInlineYear = activeTick.width >= 104
            // Find the tick that owns this year's static badge (either Jan 1 or the very first tick in the model)
            let ownerTick = model.yearStartTick(forYear: activeTick.year)
                ?? (model.monthTicks.first?.year == activeTick.year ? model.monthTicks.first : nil)
            let ownerScrolledOff = ownerTick.map { $0.x < scrollTracker.offsetX - 8 } ?? false
            let nextYearTick = model.nextYearStartTick(afterYear: activeTick.year)
            let distanceToNext = nextYearTick.map { $0.x - scrollTracker.offsetX } ?? .greatestFiniteMagnitude

            if !showInlineYear && ownerScrolledOff && distanceToNext > 72 {
                let isDark = colorScheme == .dark
                let fade = min(1.0, max(0.0, Double((distanceToNext - 72) / 36)))

                Text(String(activeTick.year))
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary.opacity(0.86))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4.5, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                            .strokeBorder(Color.primary.opacity(isDark ? 0.16 : 0.12), lineWidth: 0.65)
                    )
                    .shadow(color: .black.opacity(isDark ? 0.22 : 0.08), radius: 3, x: 0, y: 1)
                    .opacity(fade)
                    .offset(x: scrollTracker.offsetX + 12, y: 4.5)
                    .allowsHitTesting(false)
            }
        }
    }
}
