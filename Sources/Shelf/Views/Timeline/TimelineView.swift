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

    @State private var hover = TimelineHoverState()
    @State private var scrollTracker = TimelineScrollTracker()
    @State private var presetZoom: Double?
    @State private var presetTarget: Double?
    @State private var presetCommand: TimelinePresetZoomCommand?
    @State private var presetCommandNonce = 0
    @State private var scrollCommand: TimelineScrollCommand?
    @State private var scrollCommandNonce = 0
    @State private var showUndatedPopover = false
    @State private var hasPerformedInitialScroll = false
    @State private var livePinchZoom: Double?

    private let groupHeaderHeight: CGFloat = 38
    private let laneHeight: CGFloat = TimelineCardView.totalLaneHeight
    private let laneSpacing: CGFloat = 14
    private let multiGroupTopPadding: CGFloat = 10
    private let singleGroupTopPadding: CGFloat = 36
    private let groupBottomPadding: CGFloat = 22
    private let canvasBottomReserve: CGFloat = 40
    private let canvasCoordinateSpace = "shelf.timelineCanvas"

    private var activeZoom: Double {
        livePinchZoom ?? presetZoom ?? effectiveZoom
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
            abs($0.zoomValue - (presetTarget ?? activeZoom)) < abs($1.zoomValue - (presetTarget ?? activeZoom))
        }.flatMap { abs($0.zoomValue - (presetTarget ?? activeZoom)) < 0.10 ? $0 : nil }
    }

    var body: some View {
        let model = layout

        VStack(spacing: 0) {
            TimelineHeaderBar(
                model: model,
                activePreset: activePreset,
                scrollTracker: scrollTracker,
                language: language,
                showUndatedPopover: $showUndatedPopover,
                onSelectPreset: { selectPreset($0) },
                onJumpToX: { targetX, anchor in
                    triggerSmoothScroll(toX: targetX, anchor: anchor, animated: !reduceMotion)
                },
                onSelectUndatedItem: { id in
                    actions.onEnsureSelectItem(id)
                }
            )
            ShelfHairline()

            if model.scheduledCount == 0 {
                emptyTimelineState(model: model)
            } else {
                timelineCanvas(model: model)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: store.timelineCategories) { _, _ in hover.clear() }
        .onChange(of: posters) { _, _ in hover.clear() }
        .onChange(of: selectedItemID) { _, _ in hover.clear() }
        .onChange(of: effectiveZoom) { _, value in
            hover.clear()
            if let presetTarget, value != presetTarget { cancelPresetAnimation() }
        }
        .onChange(of: reduceMotion) { _, reduced in
            if reduced { cancelPresetAnimation() }
        }
        .onDisappear {
            cancelPresetAnimation()
            hover.clear()
        }
    }

    private func cancelPresetAnimation() {
        presetCommand = nil
        presetZoom = nil
        presetTarget = nil
    }

    private func selectPreset(_ target: Double) {
        let start = activeZoom
        cancelPresetAnimation()
        hover.clear()
        zoom = target
        guard !reduceMotion, abs(start - target) > 0.001 else { return }
        presetTarget = target
        presetZoom = start
        presetCommandNonce += 1
        presetCommand = TimelinePresetZoomCommand(nonce: presetCommandNonce, fromZoom: start, toZoom: target)
    }

    // MARK: - Main Timeline Canvas

    private func timelineCanvas(model: TimelineLayoutModel) -> some View {
        let rulerHeight = TimelineBottomAxisView.rulerHeight

        return GeometryReader { viewport in
            let contentHeight = totalLanesHeight(
                model: model,
                minHeight: max(360, viewport.size.height - rulerHeight)
            )

            ZStack {
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

                                TimelineCanvasBackdrop(model: model, height: contentHeight)

                                TimelineTodayGuideLine(todayX: model.todayX, height: contentHeight)

                                swimlanesContent(model: model)
                            }
                            .frame(width: model.totalWidth, height: contentHeight, alignment: .topLeading)
                        }
                        .frame(width: model.totalWidth)
                        .frame(maxHeight: .infinity)

                        TimelineBottomAxisView(
                            model: model,
                            scrollTracker: scrollTracker,
                            language: language
                        )
                        .background(
                            TimelineZoomBridge(
                                effectiveZoom: activeZoom,
                                pointsPerDay: pointsPerDay,
                                totalWidth: model.totalWidth,
                                leadingPadding: TimelineLayoutModel.leadingCanvasPadding,
                                animatingPreset: presetTarget != nil,
                                scrollCommand: scrollCommand,
                                presetCommand: presetCommand,
                                onScroll: {
                                    hover.clear()
                                    if let presetZoom {
                                        cancelPresetAnimation()
                                        zoom = presetZoom
                                    }
                                },
                                onPinchBegin: {
                                    livePinchZoom = activeZoom
                                    hover.clear()
                                    cancelPresetAnimation()
                                },
                                onPinchChanged: { nextZoom in
                                    livePinchZoom = nextZoom
                                },
                                onPinchEnded: { finalZoom in
                                    zoom = finalZoom
                                    livePinchZoom = nil
                                },
                                onPresetFrame: { nextZoom in
                                    presetZoom = nextZoom
                                },
                                onPresetFinished: {
                                    cancelPresetAnimation()
                                },
                                onViewportChanged: { originX, width in
                                    scrollTracker.update(offsetX: originX, viewportWidth: width)
                                }
                            )
                        )
                    }
                }
                .onAppear {
                    if !hasPerformedInitialScroll {
                        hasPerformedInitialScroll = true
                        let initialX = model.monthTicks
                            .first(where: { $0.id == model.latestActivityMonthID })
                            .map { $0.x + $0.width } ?? model.todayX
                        DispatchQueue.main.async {
                            triggerSmoothScroll(toX: initialX, anchor: .trailing, animated: false)
                        }
                    }
                }

                TimelinePreviewOverlay(hover: hover, containerSize: viewport.size, language: language)
                    .allowsHitTesting(false)
            }
            .coordinateSpace(name: canvasCoordinateSpace)
        }
    }

    // MARK: - Swimlanes & Sticky Category Headers

    private func swimlanesContent(model: TimelineLayoutModel) -> some View {
        let showGroupHeaders = model.groups.count > 1
        let topPad = showGroupHeaders ? multiGroupTopPadding : singleGroupTopPadding

        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(model.groups.enumerated()), id: \.element.id) { index, group in
                let lanesBlockHeight =
                    topPad
                    + CGFloat(group.laneCount) * laneHeight
                    + CGFloat(max(0, group.laneCount - 1)) * laneSpacing
                    + groupBottomPadding

                VStack(alignment: .leading, spacing: 0) {
                    if index > 0 {
                        Rectangle()
                            .fill(Color.primary.opacity(0.08))
                            .frame(width: model.totalWidth, height: 0.8)
                    }

                    if showGroupHeaders {
                        ZStack(alignment: .leading) {
                            Color.clear
                                .frame(width: model.totalWidth, height: groupHeaderHeight)

                            TimelineStickyGroupHeader(
                                group: group,
                                totalWidth: model.totalWidth,
                                scrollTracker: scrollTracker
                            )
                        }
                        .padding(.top, index == 0 ? 10 : 6)
                        .zIndex(3)
                    }

                    ZStack(alignment: .topLeading) {
                        ForEach(group.entries) { entry in
                            let y = topPad + CGFloat(entry.lane) * (laneHeight + laneSpacing)
                            let isSelected = selectedItemID == entry.id

                            TimelineCardView(
                                entry: entry,
                                showCategoryGlyph: !showGroupHeaders && store.timelineCategories.count > 1,
                                isSelected: isSelected,
                                hover: hover,
                                scrollTracker: scrollTracker,
                                language: language,
                                coordinateSpaceName: canvasCoordinateSpace,
                                actions: actions
                            )
                            .offset(x: entry.x, y: y)
                            .zIndex(isSelected ? 2 : 1)
                        }
                    }
                    .frame(width: model.totalWidth, height: lanesBlockHeight, alignment: .topLeading)
                }
            }
        }
    }

    private func totalLanesHeight(model: TimelineLayoutModel, minHeight: CGFloat) -> CGFloat {
        let showGroupHeaders = model.groups.count > 1
        let topPad = showGroupHeaders ? multiGroupTopPadding : singleGroupTopPadding
        var sum: CGFloat = 0
        for (index, group) in model.groups.enumerated() {
            if showGroupHeaders {
                sum += groupHeaderHeight + (index == 0 ? 10 : 6)
            }
            sum += topPad
            sum += CGFloat(group.laneCount) * laneHeight
            sum += CGFloat(max(0, group.laneCount - 1)) * laneSpacing
            sum += groupBottomPadding
        }
        return max(minHeight, sum + canvasBottomReserve)
    }

    // MARK: - Empty State

    private func emptyTimelineState(model: TimelineLayoutModel) -> some View {
        let allDisabled = store.timelineCategories.isEmpty

        return VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.primary.opacity(0.05))
                    .frame(width: 68, height: 68)
                Image(systemName: allDisabled ? "slider.horizontal.3" : "calendar.day.timeline.left")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 6) {
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
            }

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
                        TimelineUndatedPopover(
                            posters: model.undatedPosters,
                            language: language
                        ) { itemID in
                            showUndatedPopover = false
                            actions.onEnsureSelectItem(itemID)
                        }
                    }
                }
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func triggerSmoothScroll(toX x: CGFloat, anchor: TimelineScrollCommand.Anchor, animated: Bool) {
        hover.clear()
        scrollCommandNonce += 1
        scrollCommand = TimelineScrollCommand(nonce: scrollCommandNonce, targetX: x, anchor: anchor, animated: animated)
    }
}
