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
    let onAddItem: () -> Void
}

struct TimelineView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let posters: [LibraryPoster]
    let selectedItemID: UUID?
    @Binding var zoom: Double
    let effectiveZoom: Double
    let language: AppLanguage
    let actions: TimelineActions

    @State private var hoveredEntry: TimelineEntry?
    @State private var hoveredAnchorRect: CGRect = .zero
    @State private var showUndatedPopover = false
    @State private var undatedQuery = ""
    @State private var scrollToTargetID: String?
    @State private var scrollTargetAnchor: UnitPoint = .center
    @State private var scrollNonce = 0
    @State private var hasPerformedInitialScroll = false
    @State private var livePinchZoom: Double?

    private let rulerHeight: CGFloat = 54
    private let groupHeaderHeight: CGFloat = 34
    private let laneHeight: CGFloat = 68
    private let laneSpacing: CGFloat = 12
    private let groupTopPadding: CGFloat = 14
    private let groupBottomPadding: CGFloat = 22
    private let canvasCoordinateSpace = "shelf.timelineCanvas"

    private var activeZoom: Double {
        livePinchZoom ?? effectiveZoom
    }

    private var pointsPerDay: CGFloat {
        TimelineZoomConfig.pointsPerDay(for: activeZoom)
    }

    private var layout: TimelineLayoutModel {
        TimelineLayoutModel.build(
            posters: posters,
            includedCategories: store.timelineCategories,
            groupByCategory: store.timelineCategories.count > 1,
            pointsPerDay: pointsPerDay,
            language: language
        )
    }

    private var activePreset: TimelineZoomConfig.Preset? {
        TimelineZoomConfig.Preset.allCases.min {
            abs($0.zoomValue - activeZoom) < abs($1.zoomValue - activeZoom)
        }.flatMap { abs($0.zoomValue - activeZoom) < 0.08 ? $0 : nil }
    }

    var body: some View {
        let model = layout

        VStack(spacing: 0) {
            timelineHeaderBar(model: model)
            Divider()

            if model.scheduledCount == 0 {
                emptyTimelineState(model: model)
            } else {
                timelineCanvas(model: model)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: store.timelineCategories) { _, _ in
            hoveredEntry = nil
        }
        .onChange(of: posters.count) { _, _ in
            if let hovered = hoveredEntry, !posters.contains(where: { $0.id == hovered.id }) {
                hoveredEntry = nil
            }
        }
    }

    // MARK: - Unified Clean Top Control Bar

    private func timelineHeaderBar(model: TimelineLayoutModel) -> some View {
        HStack(spacing: 10) {
            // Multi-select Category Toggle Chips (Game / Text / Video)
            HStack(spacing: 6) {
                ForEach(MediaCategory.allCases) { category in
                    let isOn = store.timelineCategories.contains(category)
                    let count = model.datedCountByCategory[category, default: 0]
                    CategoryToggleChip(
                        category: category,
                        count: count,
                        isSelected: isOn,
                        language: language
                    ) {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                            store.toggleTimelineCategory(category)
                        }
                    }
                }
            }
            .fixedSize()

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    Divider().frame(height: 16).opacity(0.55)
                    statusFilterMenu
                    undatedButton(model: model, compact: false)
                }

                HStack(spacing: 8) {
                    Divider().frame(height: 16).opacity(0.55)
                    statusFilterMenu
                    undatedButton(model: model, compact: true)
                }

                HStack(spacing: 6) {
                    Divider().frame(height: 16).opacity(0.55)
                    statusFilterMenu
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Zoom presets (Year / Quarter / Month / Week)
            HStack(spacing: 2) {
                ForEach(TimelineZoomConfig.Preset.allCases) { preset in
                    let isSelected = activePreset == preset
                    Button {
                        hoveredEntry = nil
                        zoom = preset.zoomValue
                    } label: {
                        Text(preset.title(in: language))
                            .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(isSelected ? Color.white : Color.secondary)
                            .padding(.horizontal, 8)
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
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .fixedSize()

            Button {
                triggerScroll(to: model.todayMonthID, anchor: .center)
            } label: {
                Text(language.tr("今天", "Today"))
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .buttonStyle(
                ShelfButtonStyle(
                    variant: .secondary,
                    horizontalPadding: 10,
                    verticalPadding: 5,
                    cornerRadius: 7
                )
            )
            .fixedSize()
            .help(language.tr("跳转到今天所在月份", "Jump to today"))

            Button(action: actions.onAddItem) {
                Image(systemName: "plus")
                    .font(.system(size: 11.5, weight: .bold))
            }
            .buttonStyle(
                ShelfButtonStyle(
                    variant: .primary,
                    horizontalPadding: 9,
                    verticalPadding: 5.5,
                    cornerRadius: 7.5
                )
            )
            .fixedSize()
            .disabled(!store.isReady)
            .help(language.tr("添加新作品 (⌘N)", "Add new item (⌘N)"))
        }
        .padding(.horizontal, ShelfTheme.horizontalPadding)
        .padding(.vertical, 9)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func undatedButton(model: TimelineLayoutModel, compact: Bool) -> some View {
        if !model.undatedPosters.isEmpty {
            Button {
                undatedQuery = ""
                showUndatedPopover.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "calendar.badge.plus")
                        .font(.system(size: 11, weight: .medium))
                    Text(
                        compact
                            ? "\(model.undatedPosters.count)"
                            : language.tr("待补 \(model.undatedPosters.count)", "Undated \(model.undatedPosters.count)")
                    )
                    .font(.system(size: 11.5, weight: .medium))
                    .monospacedDigit()
                    .lineLimit(1)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8.5)
                .padding(.vertical, 4.5)
                .background(Color.primary.opacity(0.055), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .popover(isPresented: $showUndatedPopover, arrowEdge: .bottom) {
                undatedPopover(posters: model.undatedPosters)
            }
            .help(language.tr("查看当前分类下未设日期的作品，点击可在右侧补录", "Browse undated items and set dates in the detail panel"))
        }
    }

    private var statusFilterMenu: some View {
        let activeStatus: TrackingStatus? = {
            if case .single(let st) = store.statusFilter { return st }
            return nil
        }()

        return Menu {
            Button {
                store.statusFilter = .allShelves
            } label: {
                if activeStatus == nil {
                    Label(language.tr("全部状态", "All Statuses"), systemImage: "checkmark")
                } else {
                    Text(language.tr("全部状态", "All Statuses"))
                }
            }
            Divider()
            ForEach(TrackingStatus.filterOrder) { st in
                Button {
                    store.statusFilter = .single(st)
                } label: {
                    if activeStatus == st {
                        Label(st.genericTitle(in: language), systemImage: "checkmark")
                    } else {
                        Text(st.genericTitle(in: language))
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                if let activeStatus {
                    Circle()
                        .fill(activeStatus.tintColor)
                        .frame(width: 6, height: 6)
                    Text(activeStatus.genericTitle(in: language))
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.primary)
                } else {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(language.tr("状态", "Status"))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4.5)
            .background(
                activeStatus != nil ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.055),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(language.tr("按状态筛选时间线", "Filter timeline by status"))
    }

    // MARK: - Main Timeline Canvas

    private func timelineCanvas(model: TimelineLayoutModel) -> some View {
        GeometryReader { viewport in
            let contentHeight = totalLanesHeight(
                model: model,
                minHeight: max(360, viewport.size.height - rulerHeight - 1)
            )

            ZStack {
                ScrollViewReader { scrollProxy in
                    ScrollView(.horizontal, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 0) {
                            ScrollView(.vertical, showsIndicators: true) {
                                ZStack(alignment: .topLeading) {
                                    // Background tap to deselect
                                    Color.clear
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            actions.onDeselectAll()
                                        }

                                    monthGridlines(model: model, height: contentHeight)

                                    todayGuideLine(model: model, height: contentHeight)

                                    swimlanesContent(model: model)
                                }
                                .frame(width: model.totalWidth, height: contentHeight, alignment: .topLeading)
                            }
                            .frame(width: model.totalWidth)
                            .frame(maxHeight: .infinity)

                            Divider()
                                .opacity(0.75)

                            bottomTimeAxis(model: model)
                                .frame(width: model.totalWidth, height: rulerHeight, alignment: .topLeading)
                                .background(
                                    TimelineZoomBridge(
                                        effectiveZoom: activeZoom,
                                        pointsPerDay: pointsPerDay,
                                        totalWidth: model.totalWidth,
                                        leadingPadding: TimelineLayoutModel.leadingCanvasPadding,
                                        onPinchBegin: {
                                            hoveredEntry = nil
                                        },
                                        onPinchChanged: { nextZoom in
                                            livePinchZoom = nextZoom
                                        },
                                        onPinchEnded: { finalZoom in
                                            zoom = finalZoom
                                            livePinchZoom = nil
                                        }
                                    )
                                )
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
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.32)) {
                            scrollProxy.scrollTo(target, anchor: scrollTargetAnchor)
                        }
                    }
                }

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
                                insertion: .scale(scale: 0.88).combined(with: .opacity),
                                removal: .scale(scale: 0.94).combined(with: .opacity)
                            )
                    )
                    .zIndex(100)
                }
            }
            .coordinateSpace(name: canvasCoordinateSpace)
            .animation(
                reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.82),
                value: hoveredEntry?.id
            )
        }
    }

    // MARK: - Bottom Time Axis Ruler

    private func bottomTimeAxis(model: TimelineLayoutModel) -> some View {
        ZStack(alignment: .topLeading) {
            Color(nsColor: .windowBackgroundColor)

            // Layout-participating month columns so ScrollViewReader scrolls accurately
            HStack(spacing: 0) {
                Color.clear
                    .frame(width: TimelineLayoutModel.leadingCanvasPadding, height: rulerHeight)

                ForEach(Array(model.monthTicks.enumerated()), id: \.element.id) { index, tick in
                    bottomMonthAxisCell(tick: tick, showYearBelow: tick.isYearStart || index == 0)
                        .frame(width: tick.width, height: rulerHeight, alignment: .topLeading)
                        .id(tick.id)
                }
            }

            // Sleek Today indicator anchored cleanly on the bottom time axis
            VStack(spacing: 0) {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 1.5, height: 8)
                Text(language.tr("今天", "Today"))
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(Color.accentColor, in: Capsule())
                    .shadow(color: Color.accentColor.opacity(0.4), radius: 5, x: 0, y: 1.5)
                Spacer(minLength: 0)
            }
            .position(x: model.todayX, y: rulerHeight / 2)
            .allowsHitTesting(false)
        }
    }

    private func bottomMonthAxisCell(tick: TimelineMonthTick, showYearBelow: Bool) -> some View {
        let monthTitle = formattedMonthLabel(tick.month)
        let showDayTicks = pointsPerDay >= 5.5
        let dayStep = pointsPerDay >= 15 ? 1 : (pointsPerDay >= 9 ? 5 : 10)
        let showInlineYear = tick.width >= 96

        return ZStack(alignment: .topLeading) {
            if tick.isCurrentMonth {
                Color.accentColor.opacity(0.045)
            }

            // Upward-facing hairline boundary tick
            Rectangle()
                .fill(Color.primary.opacity(tick.isYearStart ? 0.24 : 0.10))
                .frame(width: tick.isYearStart ? 1 : 0.6, height: tick.isYearStart ? rulerHeight : 14)

            if showDayTicks {
                ZStack(alignment: .topLeading) {
                    ForEach(Array(stride(from: dayStep == 1 ? 1 : dayStep, through: tick.dayCount, by: dayStep)), id: \.self) { day in
                        let dayOffsetX = CGFloat(day - 1) * pointsPerDay
                        if dayOffsetX + 16 <= tick.width {
                            VStack(alignment: .leading, spacing: 1) {
                                Rectangle()
                                    .fill(Color.primary.opacity(0.14))
                                    .frame(width: 0.6, height: 5)
                                Text("\(day)")
                                    .font(.system(size: 9, weight: .medium, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(.tertiary)
                            }
                            .offset(x: dayOffsetX + 2)
                        }
                    }
                }
                .frame(height: 18, alignment: .topLeading)
            }

            VStack(alignment: .leading, spacing: 2) {
                Spacer(minLength: 0)

                if showInlineYear {
                    Text(formattedYearMonthLabel(year: tick.year, month: tick.month))
                        .font(.system(size: 12, weight: tick.isCurrentMonth ? .bold : .semibold))
                        .foregroundStyle(tick.isCurrentMonth ? Color.accentColor : .primary.opacity(0.86))
                        .lineLimit(1)
                } else {
                    if tick.width >= 30 {
                        Text(monthTitle)
                            .font(.system(size: 11.5, weight: tick.isCurrentMonth ? .bold : (tick.isYearStart ? .semibold : .medium)))
                            .foregroundStyle(tick.isCurrentMonth ? Color.accentColor : (tick.isYearStart ? .primary : .secondary))
                            .lineLimit(1)
                    }

                    if showYearBelow {
                        Text(String(tick.year))
                            .font(.system(size: 10.5, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.primary.opacity(0.68))
                            .tracking(0.4)
                            .lineLimit(1)
                    } else {
                        // Keep month baseline aligned cleanly across the year
                        Text(" ")
                            .font(.system(size: 10.5))
                    }
                }
            }
            .padding(.leading, 7)
            .padding(.bottom, 7)
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

    // MARK: - Subtle Canvas Hairlines & Today Marker

    private func monthGridlines(model: TimelineLayoutModel, height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(model.monthTicks) { tick in
                if tick.isCurrentMonth {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.025))
                        .frame(width: tick.width, height: height)
                        .offset(x: tick.x)
                }

                Rectangle()
                    .fill(Color.primary.opacity(tick.isYearStart ? 0.13 : 0.048))
                    .frame(width: tick.isYearStart ? 1 : 0.6, height: height)
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
                        Color.accentColor.opacity(0.08),
                        Color.accentColor.opacity(0.28),
                        Color.accentColor.opacity(0.80)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: 1.5, height: height)
            .shadow(color: Color.accentColor.opacity(0.35), radius: 5, x: 0, y: 0)
            .offset(x: model.todayX - 0.75)
            .allowsHitTesting(false)
    }

    // MARK: - Swimlanes & Artwork-Infused Timeline Cards

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
                            .opacity(0.45)
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
                                .foregroundStyle(.primary.opacity(0.88))
                            Text("\(group.entries.count)")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6.5)
                                .padding(.vertical, 1.5)
                                .background(Color.primary.opacity(0.06), in: Capsule())
                        }
                        .padding(.leading, TimelineLayoutModel.leadingCanvasPadding)
                        .padding(.top, 8)
                        .frame(height: groupHeaderHeight, alignment: .leading)
                    }

                    ZStack(alignment: .topLeading) {
                        ForEach(group.entries) { entry in
                            let y = groupTopPadding + CGFloat(entry.lane) * (laneHeight + laneSpacing)
                            let isSelected = selectedItemID == entry.id
                            let isHovered = hoveredEntry?.id == entry.id

                            TimelineCardView(
                                entry: entry,
                                height: laneHeight,
                                showCategoryGlyph: showGroupHeaders == false && store.timelineCategories.count > 1,
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
        return max(minHeight, sum + 28)
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
                Text(language.tr("待补录日期", "Undated Items"))
                    .font(.system(size: 13, weight: .bold))
                Spacer()
                Text("\(filtered.count)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.08), in: Capsule())
            }

            Text(language.tr("点击任意作品打开右侧详情栏，即可补录开始 / 结束日期。", "Click any item to open details and set start/end dates."))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            if posters.count > 8 {
                TextField(language.tr("搜索作品…", "Filter items…"), text: $undatedQuery)
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
                                CoverPreview(fileName: poster.coverFileName) { artwork in
                                    TimelineMiniPoster(
                                        image: artwork?.image,
                                        category: poster.category,
                                        paletteSeed: poster.paletteSeed,
                                        width: 24,
                                        height: 36,
                                        cornerRadius: 4.5
                                    )
                                }

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
        let allDisabled = store.timelineCategories.isEmpty

        return VStack(spacing: 14) {
            Image(systemName: allDisabled ? "slider.horizontal.3" : "calendar.day.timeline.left")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)

            Text(
                allDisabled
                    ? language.tr("尚未勾选要显示的分类", "No Categories Selected")
                    : language.tr("当前筛选下还没有设置日期的作品", "No Dated Items in Current View")
            )
            .font(.system(size: 15, weight: .semibold))

            Text(
                allDisabled
                    ? language.tr("请在上方开启「游戏」「文字」或「影像」开关以查看对应时间线。", "Enable Games, Texts, or Videos above to display them on the timeline.")
                    : language.tr("点击下方待补录列表，或在作品详情栏中填入起止日期后，就会出现在这张时间线上。", "Pick an undated item below or add dates in the detail panel to see it here.")
            )
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 360)

            HStack(spacing: 10) {
                if allDisabled || store.timelineCategories.count < MediaCategory.allCases.count {
                    Button(language.tr("显示全部类别", "Show All Categories")) {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                            store.timelineCategories = Set(MediaCategory.allCases)
                        }
                    }
                    .buttonStyle(ShelfButtonStyle(variant: .primary, horizontalPadding: 14, verticalPadding: 7, cornerRadius: 8))
                }

                if !model.undatedPosters.isEmpty {
                    Button(language.tr("待补日期 (\(model.undatedPosters.count))", "Pick Undated (\(model.undatedPosters.count))")) {
                        undatedQuery = ""
                        showUndatedPopover = true
                    }
                    .buttonStyle(
                        ShelfButtonStyle(
                            variant: allDisabled ? .secondary : .primary,
                            horizontalPadding: 14,
                            verticalPadding: 7,
                            cornerRadius: 8
                        )
                    )
                    .popover(isPresented: $showUndatedPopover, arrowEdge: .bottom) {
                        undatedPopover(posters: model.undatedPosters)
                    }
                }
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func triggerScroll(to monthID: String, anchor: UnitPoint) {
        scrollToTargetID = monthID
        scrollTargetAnchor = anchor
        scrollNonce += 1
    }
}

// MARK: - Category Multi-Select Toggle Chip

private struct CategoryToggleChip: View {
    let category: MediaCategory
    let count: Int
    let isSelected: Bool
    let language: AppLanguage
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        let tint = category.accentColor

        Button(action: action) {
            HStack(spacing: 5.5) {
                Image(systemName: category.systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isSelected ? tint : Color.secondary.opacity(0.55))

                Text(category.title(in: language))
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary.opacity(0.65))

                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(isSelected ? tint : Color.secondary.opacity(0.5))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            (isSelected ? tint.opacity(0.15) : Color.primary.opacity(0.05)),
                            in: Capsule()
                        )
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        isSelected
                            ? tint.opacity(isHovered ? 0.18 : 0.12)
                            : Color.primary.opacity(isHovered ? 0.065 : 0.03)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        isSelected
                            ? tint.opacity(isHovered ? 0.55 : 0.36)
                            : Color.primary.opacity(isHovered ? 0.14 : 0.08),
                        lineWidth: isSelected ? 1.0 : 0.75
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(
            isSelected
                ? language.tr("点击隐藏「\(category.title(in: language))」", "Click to hide \(category.title(in: language))")
                : language.tr("点击显示「\(category.title(in: language))」", "Click to show \(category.title(in: language))")
        )
    }
}

// MARK: - Poster-First, Artwork-Infused Timeline Card

private struct TimelineCardView: View {
    let entry: TimelineEntry
    let height: CGFloat
    let showCategoryGlyph: Bool
    let isSelected: Bool
    let isHovered: Bool
    let language: AppLanguage
    let coordinateSpaceName: String
    let onHoverChange: (Bool, CGRect) -> Void
    let actions: TimelineActions

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var lastTapAt: Date = .distantPast

    var body: some View {
        let poster = entry.poster
        let statusTint = poster.status.tintColor
        let palette = CoverPalette.forSeed(poster.paletteSeed)
        let cornerRadius: CGFloat = 13
        let progressWidth = min(max(entry.actualWidth, 24), entry.width - 14)

        CoverPreview(fileName: poster.coverFileName) { artwork in
            HStack(spacing: 11) {
                TimelineMiniPoster(
                    image: artwork?.image,
                    category: poster.category,
                    paletteSeed: poster.paletteSeed,
                    width: 38,
                    height: 56,
                    cornerRadius: 6.5
                )
                .scaleEffect(isHovered ? 1.07 : 1.0)
                .shadow(
                    color: .black.opacity(isHovered ? 0.42 : 0.24),
                    radius: isHovered ? 7 : 3.5,
                    x: 0,
                    y: isHovered ? 3 : 1.5
                )

                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(poster.title)
                            .font(.system(size: 13, weight: isSelected ? .bold : .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Spacer(minLength: 2)

                        if poster.rating > 0 {
                            HStack(spacing: 2) {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(ShelfTheme.starGold)
                                Text("\(poster.rating)")
                                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 5.5)
                            .padding(.vertical, 1.5)
                            .background(Color.primary.opacity(0.07), in: Capsule())
                        }
                    }

                    HStack(spacing: 6) {
                        Circle()
                            .fill(statusTint)
                            .frame(width: 6, height: 6)
                            .shadow(color: statusTint.opacity(entry.isOngoing ? 0.8 : 0.3), radius: entry.isOngoing ? 3.5 : 1)

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
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                        if entry.width >= 210 {
                            Text("·")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)

                            Text(
                                TimelineDateFormatter.durationText(
                                    days: entry.durationDays,
                                    isOngoing: entry.isOngoing,
                                    language: language
                                )
                            )
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(statusTint.opacity(0.95))
                            .lineLimit(1)
                        }

                        Spacer(minLength: 0)

                        if showCategoryGlyph {
                            Image(systemName: poster.category.systemImage)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(poster.category.accentColor.opacity(0.75))
                        }
                    }
                }
            }
            .padding(.leading, 6)
            .padding(.trailing, 11)
            .frame(width: entry.width, height: height, alignment: .leading)
            .background {
                ZStack(alignment: .bottomLeading) {
                    // Base adaptive surface
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))

                    // Ambient blurred poster artwork wash
                    if let backdrop = artwork?.backdrop {
                        Image(decorative: backdrop, scale: 1)
                            .resizable()
                            .scaledToFill()
                            .frame(width: entry.width, height: height)
                            .opacity(
                                colorScheme == .dark
                                    ? (isHovered ? 0.36 : 0.24)
                                    : (isHovered ? 0.22 : 0.14)
                            )
                    } else {
                        LinearGradient(
                            colors: [
                                palette.top.swiftUIColor.opacity(colorScheme == .dark ? 0.28 : 0.14),
                                palette.bottom.swiftUIColor.opacity(colorScheme == .dark ? 0.16 : 0.06)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    }

                    // Soft readability veil
                    LinearGradient(
                        colors: [
                            Color(nsColor: .windowBackgroundColor).opacity(colorScheme == .dark ? 0.42 : 0.62),
                            Color(nsColor: .windowBackgroundColor).opacity(colorScheme == .dark ? 0.24 : 0.46)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )

                    // True-duration subtle bottom accent bar
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [statusTint.opacity(0.85), statusTint.opacity(entry.isOngoing ? 0.95 : 0.45)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: progressWidth, height: 2.5)
                        .padding(.leading, 7)
                        .padding(.bottom, 2)
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        isSelected
                            ? Color.accentColor
                            : (
                                isHovered
                                    ? Color.primary.opacity(0.28)
                                    : Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.10)
                            ),
                        lineWidth: isSelected ? 1.8 : (isHovered ? 1.1 : 0.75)
                    )
            )
            .shadow(
                color: .black.opacity(isHovered ? 0.26 : (isSelected ? 0.20 : (colorScheme == .dark ? 0.22 : 0.08))),
                radius: isHovered ? 12 : (isSelected ? 8 : 5),
                x: 0,
                y: isHovered ? 5 : 2
            )
            .scaleEffect(isHovered ? 1.018 : 1.0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovered)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isSelected)
        }
        .background {
            GeometryReader { geo in
                Color.clear
                    .onHover { hovering in
                        onHoverChange(hovering, geo.frame(in: .named(coordinateSpaceName)))
                    }
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
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

// MARK: - Crisp 2:3 Mini Poster

private struct TimelineMiniPoster: View {
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
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.24), lineWidth: 0.6)
        )
    }
}
