import SwiftUI

struct TimelineActions {
    let onSelectItem: (UUID) -> Void
    let onEnsureSelectItem: (UUID) -> Void
    let onDeselectAll: () -> Void
    let onDoubleClickEdit: (UUID) -> Void
    let onRequestEditTags: (UUID) -> Void
    let onRequestReplaceCover: (UUID) -> Void
    let onChangeStatus: (UUID, TrackingStatus) -> Void
    let onChangeRating: (UUID, Int) -> Void
    let onClearDates: (UUID) -> Void
    let onDeleteItem: (UUID) -> Void
    let onSwitchToGrid: () -> Void
}

struct TimelineView: View {
    let posters: [LibraryPoster]
    let groupByCategory: Bool
    let selectedItemID: UUID?
    @Binding var zoom: Double
    let effectiveZoom: Double
    let language: AppLanguage
    let actions: TimelineActions

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveredEntry: TimelineEntry?
    @State private var hoveredAnchorRect: CGRect = .zero
    @State private var showUndatedPopover = false
    @State private var undatedQuery = ""
    @State private var scrollToTargetID: String?
    @State private var scrollNonce = 0
    @State private var hasPerformedInitialScroll = false
    @State private var pinchStartZoom: Double?

    private let rulerHeight: CGFloat = 46
    private let groupHeaderHeight: CGFloat = 34
    private let laneHeight: CGFloat = 44
    private let laneSpacing: CGFloat = 8
    private let groupTopPadding: CGFloat = 10
    private let groupBottomPadding: CGFloat = 16
    private let canvasCoordinateSpace = "shelf.timelineCanvas"

    private var pointsPerDay: CGFloat {
        TimelineZoomConfig.pointsPerDay(for: effectiveZoom)
    }

    private var layout: TimelineLayoutModel {
        TimelineLayoutModel.build(
            posters: posters,
            groupByCategory: groupByCategory,
            pointsPerDay: pointsPerDay,
            language: language
        )
    }

    private var activePreset: TimelineZoomConfig.Preset? {
        TimelineZoomConfig.Preset.allCases.min {
            abs($0.zoomValue - effectiveZoom) < abs($1.zoomValue - effectiveZoom)
        }.flatMap { abs($0.zoomValue - effectiveZoom) < 0.08 ? $0 : nil }
    }

    var body: some View {
        let model = layout

        VStack(spacing: 0) {
            timelineSubToolbar(model: model)
            Divider()

            if model.scheduledCount == 0 {
                emptyTimelineState(model: model)
            } else {
                timelineCanvas(model: model)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: posters.count) { _, _ in
            if let hovered = hoveredEntry, !posters.contains(where: { $0.id == hovered.id }) {
                hoveredEntry = nil
            }
        }
    }

    // MARK: - Sub-Toolbar

    private func timelineSubToolbar(model: TimelineLayoutModel) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Label(
                    language.tr(
                        "时间线已排期 \(model.scheduledCount) 项",
                        "\(model.scheduledCount) on timeline"
                    ),
                    systemImage: "calendar.day.timeline.left"
                )
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

                if !model.undatedPosters.isEmpty {
                    Button {
                        undatedQuery = ""
                        showUndatedPopover.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "clock.badge.questionmark")
                                .font(.system(size: 11, weight: .medium))
                            Text(
                                language.tr(
                                    "未设日期 (\(model.undatedPosters.count))",
                                    "Undated (\(model.undatedPosters.count))"
                                )
                            )
                            .font(.system(size: 11.5, weight: .medium))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                        .overlay(
                            Capsule()
                                .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.7)
                        )
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showUndatedPopover, arrowEdge: .bottom) {
                        undatedPopover(posters: model.undatedPosters)
                    }
                    .help(language.tr("查看尚未设置日期的作品，点击后可在右侧补录日期", "Browse undated items and click any to set dates in the detail panel"))
                }
            }

            Spacer(minLength: 12)

            // Zoom presets (Year / Quarter / Month / Week)
            HStack(spacing: 2) {
                ForEach(TimelineZoomConfig.Preset.allCases) { preset in
                    let isSelected = activePreset == preset
                    Button {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                            zoom = preset.zoomValue
                        }
                    } label: {
                        Text(preset.title(in: language))
                            .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(isSelected ? Color.white : Color.secondary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(isSelected ? Color.accentColor : Color.clear)
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            Button {
                triggerScroll(to: model.todayMonthID)
            } label: {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                    Text(language.tr("今天", "Today"))
                        .font(.system(size: 11.5, weight: .semibold))
                }
            }
            .buttonStyle(
                ShelfButtonStyle(
                    variant: .secondary,
                    horizontalPadding: 10,
                    verticalPadding: 4.5,
                    cornerRadius: 7
                )
            )
            .help(language.tr("跳转到今天所在月份", "Jump to today"))
        }
        .padding(.horizontal, ShelfTheme.horizontalPadding)
        .padding(.vertical, 7)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Main Timeline Canvas

    private func timelineCanvas(model: TimelineLayoutModel) -> some View {
        GeometryReader { viewport in
            let contentHeight = totalLanesHeight(model: model, minHeight: max(320, viewport.size.height - rulerHeight - 1))

            ZStack {
                ScrollViewReader { scrollProxy in
                    ScrollView(.horizontal, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 0) {
                            calendarRuler(model: model)
                                .frame(width: model.totalWidth, height: rulerHeight, alignment: .topLeading)

                            Divider()

                            ScrollView(.vertical, showsIndicators: true) {
                                ZStack(alignment: .topLeading) {
                                    // Background tap to deselect
                                    Color.clear
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            actions.onDeselectAll()
                                        }

                                    monthBandsAndGridlines(model: model, height: contentHeight)

                                    todayGuideLine(model: model, height: contentHeight)

                                    swimlanesContent(model: model)
                                }
                                .frame(width: model.totalWidth, height: contentHeight, alignment: .topLeading)
                            }
                            .frame(width: model.totalWidth)
                        }
                    }
                    .onAppear {
                        if !hasPerformedInitialScroll {
                            hasPerformedInitialScroll = true
                            let target = model.latestActivityMonthID
                            DispatchQueue.main.async {
                                scrollProxy.scrollTo(target, anchor: .trailing)
                            }
                        }
                    }
                    .onChange(of: scrollNonce) { _, _ in
                        guard let target = scrollToTargetID else { return }
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
                            scrollProxy.scrollTo(target, anchor: .center)
                        }
                    }
                }
                .simultaneousGesture(
                    MagnifyGesture()
                        .onChanged { value in
                            if hoveredEntry != nil {
                                hoveredEntry = nil
                            }
                            if pinchStartZoom == nil {
                                pinchStartZoom = zoom
                            }
                            if let base = pinchStartZoom {
                                let delta = log2(Double(max(0.25, value.magnification))) * 0.38
                                zoom = min(max(base + delta, TimelineZoomConfig.minZoom), TimelineZoomConfig.maxZoom)
                            }
                        }
                        .onEnded { _ in
                            pinchStartZoom = nil
                        }
                )

                // Floating enlarged poster preview on hover
                if let hovered = hoveredEntry, hoveredAnchorRect.width > 0 {
                    TimelineHoverPreviewCard(
                        entry: hovered,
                        anchorRect: hoveredAnchorRect,
                        containerSize: viewport.size,
                        language: language
                    )
                    .id(hovered.id)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .asymmetric(
                                insertion: .scale(scale: 0.90).combined(with: .opacity),
                                removal: .scale(scale: 0.95).combined(with: .opacity)
                            )
                    )
                    .zIndex(100)
                }
            }
            .coordinateSpace(name: canvasCoordinateSpace)
            .animation(
                reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.84),
                value: hoveredEntry?.id
            )
        }
    }

    // MARK: - Calendar Ruler

    private func calendarRuler(model: TimelineLayoutModel) -> some View {
        ZStack(alignment: .topLeading) {
            Color(nsColor: .windowBackgroundColor)

            // Layout-participating month cells so ScrollViewReader can scroll accurately to any month
            HStack(spacing: 0) {
                Color.clear
                    .frame(width: TimelineLayoutModel.leadingCanvasPadding, height: rulerHeight)

                ForEach(Array(model.monthTicks.enumerated()), id: \.element.id) { index, tick in
                    monthRulerCell(tick: tick, showYear: tick.isYearStart || index == 0)
                        .frame(width: tick.width, height: rulerHeight, alignment: .topLeading)
                        .id(tick.id)
                }
            }

            // Floating Today pill on the ruler
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                Text(language.tr("今天", "Today"))
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor, in: Capsule())
                    .shadow(color: Color.accentColor.opacity(0.35), radius: 4, x: 0, y: 1)
                    .padding(.bottom, 3)
            }
            .position(x: model.todayX, y: rulerHeight / 2)
            .allowsHitTesting(false)
        }
    }

    private func monthRulerCell(tick: TimelineMonthTick, showYear: Bool) -> some View {
        let monthTitle = formattedMonthLabel(tick.month)
        let showDayTicks = pointsPerDay >= 5.5
        let dayStep = pointsPerDay >= 15 ? 1 : (pointsPerDay >= 9 ? 5 : 10)

        return ZStack(alignment: .topLeading) {
            // Left border tick line
            Rectangle()
                .fill(Color.primary.opacity(tick.isYearStart ? 0.22 : 0.09))
                .frame(width: tick.isYearStart ? 1.2 : 0.75, height: rulerHeight)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if showYear {
                        Text(String(tick.year))
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }

                    if tick.width >= 30 {
                        Text(monthTitle)
                            .font(.system(size: 11.5, weight: tick.isYearStart ? .semibold : .medium))
                            .foregroundStyle(tick.isYearStart ? .primary : .secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.leading, 6)
                .padding(.top, 6)

                Spacer(minLength: 0)

                if showDayTicks {
                    ZStack(alignment: .bottomLeading) {
                        ForEach(Array(stride(from: dayStep == 1 ? 1 : dayStep, through: tick.dayCount, by: dayStep)), id: \.self) { day in
                            let dayOffsetX = CGFloat(day - 1) * pointsPerDay
                            if dayOffsetX + 16 <= tick.width {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("\(day)")
                                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                    Rectangle()
                                        .fill(Color.primary.opacity(0.14))
                                        .frame(width: 0.7, height: 5)
                                }
                                .offset(x: dayOffsetX + 2)
                            }
                        }
                    }
                    .frame(height: 16, alignment: .bottomLeading)
                }
            }
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

    // MARK: - Gridlines & Today Marker

    private func monthBandsAndGridlines(model: TimelineLayoutModel, height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(model.monthTicks.enumerated()), id: \.element.id) { idx, tick in
                if idx.isMultiple(of: 2) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.022))
                        .frame(width: tick.width, height: height)
                        .offset(x: tick.x)
                }

                Rectangle()
                    .fill(Color.primary.opacity(tick.isYearStart ? 0.16 : 0.065))
                    .frame(width: tick.isYearStart ? 1.2 : 0.75, height: height)
                    .offset(x: tick.x)
            }
        }
        .allowsHitTesting(false)
    }

    private func todayGuideLine(model: TimelineLayoutModel, height: CGFloat) -> some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [
                        Color.accentColor.opacity(0.75),
                        Color.accentColor.opacity(0.30)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: 1.5, height: height)
            .shadow(color: Color.accentColor.opacity(0.35), radius: 4, x: 0, y: 0)
            .offset(x: model.todayX - 0.75)
            .allowsHitTesting(false)
    }

    // MARK: - Swimlanes & Gantt Bars

    private func swimlanesContent(model: TimelineLayoutModel) -> some View {
        let showGroupHeaders = model.groups.count > 1

        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(model.groups.enumerated()), id: \.element.id) { index, group in
                let lanesBlockHeight =
                    groupTopPadding
                    + CGFloat(group.laneCount) * laneHeight
                    + CGFloat(max(0, group.laneCount - 1)) * laneSpacing
                    + groupBottomPadding

                VStack(alignment: .leading, spacing: 0) {
                    if index > 0 {
                        Divider()
                            .opacity(0.65)
                    }

                    if showGroupHeaders {
                        HStack(spacing: 7) {
                            if let category = group.category {
                                Image(systemName: category.systemImage)
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(category.accentColor)
                            }
                            Text(group.title)
                                .font(.system(size: 12.5, weight: .bold))
                                .foregroundStyle(.primary)
                            Text("\(group.entries.count)")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6.5)
                                .padding(.vertical, 1.5)
                                .background(Color.primary.opacity(0.07), in: Capsule())
                        }
                        .padding(.leading, TimelineLayoutModel.leadingCanvasPadding)
                        .frame(height: groupHeaderHeight, alignment: .leading)
                    }

                    ZStack(alignment: .topLeading) {
                        ForEach(group.entries) { entry in
                            let y = groupTopPadding + CGFloat(entry.lane) * (laneHeight + laneSpacing)
                            let isSelected = selectedItemID == entry.id
                            let isHovered = hoveredEntry?.id == entry.id

                            TimelineBarView(
                                entry: entry,
                                height: laneHeight,
                                isSelected: isSelected,
                                isHovered: isHovered,
                                language: language,
                                coordinateSpaceName: canvasCoordinateSpace,
                                onHoverChange: { hovering, rect in
                                    if hovering {
                                        hoveredEntry = entry
                                        hoveredAnchorRect = rect
                                    } else if hoveredEntry?.id == entry.id {
                                        hoveredEntry = nil
                                    }
                                },
                                actions: actions
                            )
                            .offset(x: entry.x, y: y)
                            .zIndex(isHovered ? 30 : (isSelected ? 20 : 1))
                        }
                    }
                    .frame(width: model.totalWidth, height: lanesBlockHeight, alignment: .topLeading)
                }
            }
        }
    }

    private func totalLanesHeight(model: TimelineLayoutModel, minHeight: CGFloat) -> CGFloat {
        let showGroupHeaders = model.groups.count > 1
        var sum: CGFloat = 0
        for group in model.groups {
            if showGroupHeaders {
                sum += groupHeaderHeight
            }
            sum += groupTopPadding
            sum += CGFloat(group.laneCount) * laneHeight
            sum += CGFloat(max(0, group.laneCount - 1)) * laneSpacing
            sum += groupBottomPadding
        }
        return max(minHeight, sum + 24)
    }

    // MARK: - Undated Items Popover & Empty State

    private func undatedPopover(posters: [LibraryPoster]) -> some View {
        let trimmed = undatedQuery.trimmed
        let filtered = trimmed.isEmpty
            ? posters
            : posters.filter {
                $0.title.localizedCaseInsensitiveContains(trimmed)
                    || ($0.secondaryTitle?.localizedCaseInsensitiveContains(trimmed) ?? false)
            }

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(language.tr("尚未设置时间线日期", "Items Without Dates"))
                    .font(.system(size: 13, weight: .bold))
                Spacer()
                Text("\(filtered.count)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.08), in: Capsule())
            }

            Text(language.tr("点击任意作品打开右侧详情栏，即可补录开始 / 结束日期。", "Click any item to open details and set start/end dates."))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            if posters.count > 8 {
                TextField(language.tr("筛选未设日期作品…", "Filter undated items…"), text: $undatedQuery)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(filtered, id: \.id) { poster in
                        Button {
                            showUndatedPopover = false
                            actions.onEnsureSelectItem(poster.id)
                        } label: {
                            HStack(spacing: 9) {
                                TimelineMiniCover(
                                    fileName: poster.coverFileName,
                                    category: poster.category,
                                    paletteSeed: poster.paletteSeed,
                                    width: 22,
                                    height: 33
                                )

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(poster.title)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)

                                    HStack(spacing: 5) {
                                        Circle()
                                            .fill(poster.status.tintColor)
                                            .frame(width: 5.5, height: 5.5)
                                        Text(poster.category.statusLabel(for: poster.status, in: language))
                                            .font(.system(size: 10.5))
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                Spacer(minLength: 4)

                                Image(systemName: "calendar.badge.plus")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 280)
        }
        .padding(14)
        .frame(width: 300)
    }

    private func emptyTimelineState(model: TimelineLayoutModel) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "calendar.day.timeline.left")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)

            Text(language.tr("当前筛选下还没有设置日期的作品", "No Dated Items in Current View"))
                .font(.system(size: 15, weight: .semibold))

            Text(
                language.tr(
                    "在作品详情栏或编辑窗口中填入开始/结束日期后，它们就会自动排布在这张横向时间线上。",
                    "Add a start or finish date in the detail panel or editor to see items laid out on the timeline."
                )
            )
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 360)

            HStack(spacing: 10) {
                if !model.undatedPosters.isEmpty {
                    Button(language.tr("从待补录列表选择 (\(model.undatedPosters.count))", "Pick Undated Item (\(model.undatedPosters.count))")) {
                        undatedQuery = ""
                        showUndatedPopover = true
                    }
                    .buttonStyle(ShelfButtonStyle(variant: .primary, horizontalPadding: 14, verticalPadding: 7, cornerRadius: 8))
                    .popover(isPresented: $showUndatedPopover, arrowEdge: .bottom) {
                        undatedPopover(posters: model.undatedPosters)
                    }
                }

                Button(language.tr("返回海报墙", "Back to Grid")) {
                    actions.onSwitchToGrid()
                }
                .buttonStyle(ShelfButtonStyle(variant: .secondary, horizontalPadding: 14, verticalPadding: 7, cornerRadius: 8))
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func triggerScroll(to monthID: String) {
        scrollToTargetID = monthID
        scrollNonce += 1
    }
}

// MARK: - Gantt Bar Component

private struct TimelineBarView: View {
    let entry: TimelineEntry
    let height: CGFloat
    let isSelected: Bool
    let isHovered: Bool
    let language: AppLanguage
    let coordinateSpaceName: String
    let onHoverChange: (Bool, CGRect) -> Void
    let actions: TimelineActions

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lastTapAt: Date = .distantPast

    var body: some View {
        let poster = entry.poster
        let tint = poster.status.tintColor
        let accent = poster.category.accentColor

        HStack(spacing: 8) {
            TimelineMiniCover(
                fileName: poster.coverFileName,
                category: poster.category,
                paletteSeed: poster.paletteSeed,
                width: 24,
                height: 34
            )
            .scaleEffect(isHovered ? 1.07 : 1.0)
            .shadow(color: .black.opacity(isHovered ? 0.35 : 0.18), radius: isHovered ? 5 : 2, x: 0, y: 1)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(poster.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if poster.rating > 0 && entry.width >= 150 {
                        HStack(spacing: 1.5) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 8.5))
                                .foregroundStyle(ShelfTheme.starGold)
                            Text("\(poster.rating)")
                                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                HStack(spacing: 4) {
                    Circle()
                        .fill(tint)
                        .frame(width: 5.5, height: 5.5)

                    if entry.width >= 132 {
                        Text(
                            TimelineDateFormatter.spanText(
                                start: entry.startDay,
                                end: entry.endDay,
                                isOngoing: entry.isOngoing,
                                durationDays: entry.durationDays,
                                language: language,
                                compact: entry.width < 220
                            )
                        )
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    } else {
                        Text(poster.category.statusLabel(for: poster.status, in: language))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 0)

            if entry.isOngoing {
                Circle()
                    .fill(TrackingStatus.active.tintColor)
                    .frame(width: 7, height: 7)
                    .shadow(color: TrackingStatus.active.tintColor.opacity(0.65), radius: 4, x: 0, y: 0)
                    .padding(.trailing, 2)
            }
        }
        .padding(.leading, 5)
        .padding(.trailing, 8)
        .frame(width: entry.width, height: height, alignment: .leading)
        .background {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(isSelected ? 0.96 : 0.88))

                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                accent.opacity(isHovered ? 0.22 : (isSelected ? 0.20 : 0.12)),
                                tint.opacity(isHovered ? 0.14 : (isSelected ? 0.12 : 0.06))
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )

                // Left accent stripe
                UnevenRoundedRectangle(
                    topLeadingRadius: 10,
                    bottomLeadingRadius: 10,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 0
                )
                .fill(tint.opacity(isSelected || isHovered ? 0.95 : 0.72))
                .frame(width: 3)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isSelected
                        ? Color.accentColor
                        : (isHovered ? Color.primary.opacity(0.28) : Color.primary.opacity(0.11)),
                    lineWidth: isSelected ? 1.8 : (isHovered ? 1.1 : 0.75)
                )
        )
        .shadow(
            color: .black.opacity(isHovered ? 0.22 : (isSelected ? 0.16 : 0.07)),
            radius: isHovered ? 10 : (isSelected ? 7 : 3),
            x: 0,
            y: isHovered ? 4 : 2
        )
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isHovered)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isSelected)
        .background {
            GeometryReader { geo in
                Color.clear
                    .onHover { hovering in
                        onHoverChange(hovering, geo.frame(in: .named(coordinateSpaceName)))
                    }
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture {
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
}

// MARK: - Compact Mini Cover Thumbnail

private struct TimelineMiniCover: View {
    let fileName: String?
    let category: MediaCategory
    let paletteSeed: Int
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        let palette = CoverPalette.forSeed(paletteSeed)

        CoverPreview(fileName: fileName) { artwork in
            ZStack {
                if let image = artwork?.image {
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
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 4.5, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.6)
            )
        }
    }
}
