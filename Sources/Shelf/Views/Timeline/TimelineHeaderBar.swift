import AppKit
import SwiftUI

struct TimelineHeaderBar: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    let model: TimelineLayoutModel
    let activePreset: TimelineZoomConfig.Preset?
    let scrollTracker: TimelineScrollTracker
    let language: AppLanguage
    @Binding var showUndatedPopover: Bool
    let onSelectPreset: (Double) -> Void
    let onJumpToX: (CGFloat, TimelineScrollCommand.Anchor) -> Void
    let onSelectUndatedItem: (UUID) -> Void

    @Namespace private var presetSelection

    var body: some View {
        HStack(spacing: 10) {
            // Unified recessed multi-select Category Strip (Games / Texts / Videos)
            categoryToggleStrip
                .fixedSize()

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 7) {
                    subtleDivider
                    statusFilterMenu
                    undatedTrigger(compact: false)
                }

                HStack(spacing: 7) {
                    subtleDivider
                    statusFilterMenu
                    undatedTrigger(compact: true)
                }

                HStack(spacing: 6) {
                    subtleDivider
                    statusFilterMenu
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Year Quick-Jump (appears whenever entries span multiple years)
            if model.yearJumps.count > 1 {
                TimelineYearJumpControl(
                    model: model,
                    scrollTracker: scrollTracker,
                    language: language,
                    onJumpToX: onJumpToX
                )
                .fixedSize()
            }

            // Zoom presets (Year / Quarter / Month / Week)
            zoomPresetControl
                .fixedSize()

            Button {
                onJumpToX(model.todayX, .center)
            } label: {
                Text(language.tr("今天", "Today"))
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(
                ShelfButtonStyle(
                    variant: .secondary,
                    horizontalPadding: 11,
                    verticalPadding: 5.5,
                    cornerRadius: 8
                )
            )
            .fixedSize()
            .help(language.tr("跳转到今天所在月份", "Jump to today"))
        }
        .padding(.horizontal, ShelfTheme.horizontalPadding)
        .padding(.vertical, 9)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var subtleDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.11))
            .frame(width: 0.8, height: 16)
    }

    // MARK: - Unified Category Filter Strip

    private var categoryToggleStrip: some View {
        let isDark = colorScheme == .dark

        return HStack(spacing: 3) {
            ForEach(MediaCategory.allCases) { category in
                let isOn = store.timelineCategories.contains(category)
                let count = model.datedCountByCategory[category, default: 0]
                CategoryStripSegment(
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
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(isDark ? 0.075 : 0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.primary.opacity(isDark ? 0.11 : 0.08), lineWidth: 0.75)
        )
    }

    // MARK: - Status Filter Menu

    private var statusFilterMenu: some View {
        let activeStatus: TrackingStatus? = {
            if case .single(let st) = store.statusFilter { return st }
            return nil
        }()

        return TimelineMenuPillButton(
            isHighlighted: activeStatus != nil,
            helpText: language.tr("按状态筛选时间线", "Filter timeline by status"),
            buildMenu: {
                let menu = NSMenu()
                menu.autoenablesItems = false
                menu.addItem(ClosureMenuItem(
                    title: language.tr("全部状态", "All Statuses"),
                    state: activeStatus == nil ? .on : .off
                ) {
                    store.statusFilter = .allShelves
                })
                menu.addItem(.separator())
                for st in TrackingStatus.filterOrder {
                    menu.addItem(ClosureMenuItem(
                        title: st.genericTitle(in: language),
                        state: activeStatus == st ? .on : .off
                    ) {
                        store.statusFilter = .single(st)
                    })
                }
                return menu
            }
        ) {
            HStack(spacing: 5.5) {
                if let activeStatus {
                    Circle()
                        .fill(activeStatus.tintColor)
                        .frame(width: 6.5, height: 6.5)
                    Text(activeStatus.genericTitle(in: language))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                } else {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(language.tr("状态", "Status"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.90))
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Undated Items Trigger

    @ViewBuilder
    private func undatedTrigger(compact: Bool) -> some View {
        if !model.undatedPosters.isEmpty {
            Button {
                showUndatedPopover.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "calendar.badge.plus")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(
                        compact
                            ? "\(model.undatedPosters.count)"
                            : language.tr("待补 \(model.undatedPosters.count)", "Undated \(model.undatedPosters.count)")
                    )
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .lineLimit(1)
                }
            }
            .buttonStyle(
                ShelfButtonStyle(
                    variant: .secondary,
                    horizontalPadding: 9.5,
                    verticalPadding: 5.5,
                    cornerRadius: 8
                )
            )
            .fixedSize()
            .popover(isPresented: $showUndatedPopover, arrowEdge: .bottom) {
                TimelineUndatedPopover(
                    posters: model.undatedPosters,
                    language: language
                ) { itemID in
                    showUndatedPopover = false
                    onSelectUndatedItem(itemID)
                }
            }
            .help(language.tr("查看当前分类下未设日期的作品，点击可在右侧补录", "Browse undated items and set dates in the detail panel"))
        }
    }

    // MARK: - Zoom Preset Segmented Control

    private var zoomPresetControl: some View {
        let isDark = colorScheme == .dark

        return HStack(spacing: 2) {
            ForEach(TimelineZoomConfig.Preset.allCases) { preset in
                let isSelected = activePreset == preset
                Button {
                    onSelectPreset(preset.zoomValue)
                } label: {
                    Text(preset.title(in: language))
                        .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4.5)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .strokeBorder(
                                                Color.primary.opacity(isDark ? 0.14 : 0.08),
                                                lineWidth: 0.65
                                            )
                                    )
                                    .shadow(color: .black.opacity(isDark ? 0.28 : 0.08), radius: 2.5, x: 0, y: 1)
                                    .matchedGeometryEffect(id: "selectedPreset", in: presetSelection)
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .animation(reduceMotion ? nil : ShelfMotion.control, value: activePreset)
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(isDark ? 0.075 : 0.052))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.primary.opacity(isDark ? 0.11 : 0.08), lineWidth: 0.75)
        )
    }
}

// MARK: - Category Toggle Segment (Inside Unified Recessed Strip)

private struct CategoryStripSegment: View {
    let category: MediaCategory
    let count: Int
    let isSelected: Bool
    let language: AppLanguage
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        let isDark = colorScheme == .dark
        let tint = category.accentColor

        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: category.systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isSelected ? tint : Color.secondary.opacity(isHovered ? 0.80 : 0.48))

                Text(category.title(in: language))
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary.opacity(isHovered ? 0.88 : 0.60))

                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(isSelected ? Color.secondary : Color.secondary.opacity(0.45))
                }
            }
            .padding(.horizontal, 9.5)
            .padding(.vertical, 4.5)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                                .fill(tint.opacity(isDark ? 0.09 : 0.06))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                                .strokeBorder(
                                    tint.opacity(isHovered ? 0.42 : (isDark ? 0.26 : 0.22)),
                                    lineWidth: 0.75
                                )
                        )
                        .shadow(color: .black.opacity(isDark ? 0.24 : 0.07), radius: 2, x: 0, y: 1)
                } else if isHovered {
                    RoundedRectangle(cornerRadius: 6.5, style: .continuous)
                        .fill(Color.primary.opacity(0.055))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 6.5, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : ShelfMotion.micro, value: isHovered)
        .animation(reduceMotion ? nil : ShelfMotion.control, value: isSelected)
        .onHover { isHovered = $0 }
        .help(
            isSelected
                ? language.tr("点击隐藏「\(category.title(in: language))」", "Click to hide \(category.title(in: language))")
                : language.tr("点击显示「\(category.title(in: language))」", "Click to show \(category.title(in: language))")
        )
    }
}

// MARK: - Live Year Quick-Jump Menu (Isolated Scroll Observer)

private struct TimelineYearJumpControl: View {
    let model: TimelineLayoutModel
    let scrollTracker: TimelineScrollTracker
    let language: AppLanguage
    let onJumpToX: (CGFloat, TimelineScrollCommand.Anchor) -> Void

    private var visibleYear: Int? {
        let probeX = scrollTracker.offsetX + max(24, scrollTracker.viewportWidth * 0.35)
        return model.tick(atX: probeX)?.year ?? model.yearJumps.last?.year
    }

    var body: some View {
        let currentYear = visibleYear

        TimelineMenuPillButton(
            isHighlighted: false,
            helpText: language.tr("快速跳转到指定年份", "Jump to year"),
            buildMenu: {
                let menu = NSMenu()
                menu.autoenablesItems = false
                for jump in model.yearJumps.reversed() {
                    let countLabel = language == .zh ? "\(jump.itemCount) 项" : "\(jump.itemCount)"
                    menu.addItem(ClosureMenuItem(
                        title: "\(jump.year)  ·  \(countLabel)",
                        state: currentYear == jump.year ? .on : .off
                    ) {
                        if let tick = model.monthTicks.first(where: { $0.id == jump.targetMonthID }) {
                            onJumpToX(tick.x, .leading)
                        }
                    })
                }
                return menu
            }
        ) {
            HStack(spacing: 5) {
                Image(systemName: "calendar")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(currentYear.map(String.init) ?? language.tr("年份", "Year"))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary.opacity(0.90))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Consistent Native Pill Menu Button

private struct TimelineMenuPillButton<Label: View>: View {
    let isHighlighted: Bool
    let helpText: String
    let buildMenu: () -> NSMenu
    @ViewBuilder let label: () -> Label

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @State private var anchorNSView: NSView?

    var body: some View {
        let isDark = colorScheme == .dark

        Button {
            presentMenu()
        } label: {
            label()
                .padding(.horizontal, 10)
                .padding(.vertical, 5.5)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(
                            isHighlighted
                                ? Color.accentColor.opacity(isHovered ? (isDark ? 0.24 : 0.16) : (isDark ? 0.18 : 0.12))
                                : Color.primary.opacity(isHovered ? (isDark ? 0.11 : 0.085) : (isDark ? 0.065 : 0.048))
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            isHighlighted
                                ? Color.accentColor.opacity(isHovered ? 0.48 : 0.34)
                                : Color.primary.opacity(isHovered ? (isDark ? 0.20 : 0.16) : (isDark ? 0.12 : 0.09)),
                            lineWidth: 0.75
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .animation(reduceMotion ? nil : ShelfMotion.micro, value: isHovered)
        .background(
            TimelineMenuAnchor(nsView: $anchorNSView)
                .allowsHitTesting(false)
        )
        .onHover { isHovered = $0 }
        .help(helpText)
    }

    private func presentMenu() {
        let menu = buildMenu()
        if let anchor = anchorNSView {
            let yPos: CGFloat = anchor.isFlipped ? (anchor.bounds.height + 4) : -4
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: yPos), in: anchor)
        } else if let event = NSApp.currentEvent {
            NSMenu.popUpContextMenu(menu, with: event, for: NSApp.keyWindow?.contentView ?? NSView())
        }
    }
}

private struct TimelineMenuAnchor: NSViewRepresentable {
    @Binding var nsView: NSView?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { self.nsView = view }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if nsView !== view {
            DispatchQueue.main.async { self.nsView = view }
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {}
}

// MARK: - Refined Undated Items Popover

struct TimelineUndatedPopover: View {
    let posters: [LibraryPoster]
    let language: AppLanguage
    let onSelect: (UUID) -> Void

    @State private var query = ""

    var body: some View {
        let trimmed = query.trimmed
        let filtered = trimmed.isEmpty
            ? posters
            : posters.filter {
                $0.title.localizedCaseInsensitiveContains(trimmed)
                    || ($0.secondaryTitle?.localizedCaseInsensitiveContains(trimmed) ?? false)
            }

        VStack(alignment: .leading, spacing: 10) {
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
                TextField(language.tr("搜索作品…", "Filter items…"), text: $query)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(filtered, id: \.id) { poster in
                        TimelineUndatedRow(poster: poster, language: language) {
                            onSelect(poster.id)
                        }
                    }
                }
            }
            .frame(maxHeight: 290)
        }
        .padding(14)
        .frame(width: 306)
    }
}

private struct TimelineUndatedRow: View {
    let poster: LibraryPoster
    let language: AppLanguage
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
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

                VStack(alignment: .leading, spacing: 2.5) {
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

                Image(systemName: isHovered ? "arrow.right.circle.fill" : "calendar.badge.plus")
                    .font(.system(size: 12))
                    .foregroundStyle(isHovered ? Color.accentColor : Color.secondary.opacity(0.6))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5.5)
            .background(
                Color.primary.opacity(isHovered ? 0.08 : 0.03),
                in: RoundedRectangle(cornerRadius: 7.5, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7.5, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : ShelfMotion.micro, value: isHovered)
        .onHover { isHovered = $0 }
    }
}
