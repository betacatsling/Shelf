import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ItemDetailPanel: View {
    let item: MediaItem
    let isShowing: Bool
    let onReplaceCover: () -> Void
    let onClose: () -> Void

    @Environment(LibraryStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var statusNamespace
    @State private var draftNotes: String
    @State private var isPosterHovered = false
    @State private var isTitleHovered = false
    @State private var isCategoryHovered = false
    @State private var isSubtagHovered = false
    @State private var hoveredTagPill: String? = nil
    @State private var hoveredStatus: TrackingStatus? = nil
    @State private var hoveredCategoryOption: MediaCategory? = nil
    @State private var isDeleteHovered = false
    @State private var isDropTargeted = false
    @State private var showDeleteConfirm = false

    @State private var showTitlePopover = false
    @State private var titleEditingItemID: UUID? = nil
    @State private var draftTitleZH: String = ""
    @State private var draftTitleEN: String = ""

    @State private var showCategoryPopover = false
    @State private var showSubtagPopover = false
    @State private var showTimelinePopover = false
    @State private var timelineEditingItemID: UUID? = nil
    @State private var isTimelineHovered = false
    @State private var draftHasStartDate = false
    @State private var draftStartDate = Date()
    @State private var draftHasFinishDate = false
    @State private var draftFinishDate = Date()

    init(item: MediaItem, isShowing: Bool, onReplaceCover: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.item = item
        self.isShowing = isShowing
        self.onReplaceCover = onReplaceCover
        self.onClose = onClose
        _draftNotes = State(initialValue: item.notes)
    }

    private var lang: AppLanguage { store.language }

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.calendar = Calendar(identifier: .gregorian)
        df.dateFormat = "yyyy-MM-dd"
        return df
    }()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                CoverPreview(fileName: item.coverFileName) { artwork in
                    heroHeader(artwork)
                }
                statusSwitcherSection.padding(.horizontal, 20)
                metadataCardSection.padding(.horizontal, 20)
                notesSection.padding(.horizontal, 20)
                metadataFooter.padding(.horizontal, 20)
            }
            .padding(.bottom, 22)
        }
        .frame(width: 320)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: item.id) { _, _ in
            draftNotes = item.notes
            closePopovers()
        }
        .onChange(of: isShowing) { _, showing in
            if !showing { closePopovers() }
        }
        .onChange(of: item.notes) { _, newValue in
            if draftNotes != newValue {
                draftNotes = newValue
            }
        }
        .onChange(of: showTitlePopover || showCategoryPopover || showSubtagPopover || showTimelinePopover) { _, presented in
            store.isDetailPopoverPresented = presented
        }
        .onDisappear {
            store.isDetailPopoverPresented = false
        }
        .confirmationDialog(
            lang.tr("确定要删除\(item.quotedTitle(in: lang))吗？", "Delete \(item.quotedTitle(in: lang))?"),
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button(lang.tr("删除", "Delete"), role: .destructive) {
                store.deleteItem(id: item.id)
            }
            Button(lang.tr("取消", "Cancel"), role: .cancel) {}
        }
    }

    private func closePopovers() {
        showTitlePopover = false
        showCategoryPopover = false
        showSubtagPopover = false
        showTimelinePopover = false
        showDeleteConfirm = false
    }

    // MARK: - Hero Header

    private func heroHeader(_ artwork: CoverManager.Artwork?) -> some View {
        let shownTitle = item.displayTitle(in: lang)

        return ZStack(alignment: .topTrailing) {
            ZStack {
                if let background = artwork?.backdrop {
                    Image(decorative: background, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .frame(height: 245)
                        .opacity(0.38)
                        .clipped()
                } else {
                    LinearGradient(
                        colors: [
                            item.category.accentColor.opacity(0.24),
                            Color.clear
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 245)
                }

                LinearGradient(
                    stops: [
                        .init(color: Color.clear, location: 0.0),
                        .init(color: Color(nsColor: .windowBackgroundColor).opacity(0.45), location: 0.55),
                        .init(color: Color(nsColor: .windowBackgroundColor).opacity(0.88), location: 0.82),
                        .init(color: Color(nsColor: .windowBackgroundColor), location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .frame(height: 255)
            .clipped()
            .allowsHitTesting(false)

            VStack(spacing: 12) {
                ZStack(alignment: .bottomTrailing) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.black)
                        .frame(width: 132, height: 198)
                        .shadow(
                            color: .black.opacity(isPosterHovered ? 0.38 : 0.26),
                            radius: isPosterHovered ? 16 : 11,
                            x: 0,
                            y: isPosterHovered ? 9 : 6
                        )

                    CoverArtworkView(
                        title: shownTitle,
                        category: item.category,
                        subtag: item.subtag,
                        image: artwork?.image,
                        paletteSeed: item.paletteSeed,
                        language: lang,
                        cornerRadius: 12,
                        isHovered: isPosterHovered
                    )
                    .frame(width: 132, height: 198)

                    if isPosterHovered && !isDropTargeted {
                        Image(systemName: "photo")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 26, height: 26)
                            .background(.ultraThinMaterial, in: Circle())
                            .background(Color.black.opacity(0.42), in: Circle())
                            .overlay(
                                Circle()
                                    .strokeBorder(Color.white.opacity(0.28), lineWidth: 0.7)
                            )
                            .padding(7)
                            .transition(.scale(scale: 0.85).combined(with: .opacity))
                            .allowsHitTesting(false)
                    }

                    if isDropTargeted {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.accentColor.opacity(0.32))
                            .frame(width: 132, height: 198)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                            )
                            .overlay(
                                Text(lang.tr("松开设为封面", "Drop to Set Cover"))
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color.black.opacity(0.75), in: Capsule())
                            )
                            .transition(.opacity)
                    }
                }
                .scaleEffect(!reduceMotion && isPosterHovered ? 1.02 : 1.0)
                .animation(reduceMotion ? nil : ShelfMotion.micro, value: isPosterHovered)
                .animation(reduceMotion ? nil : ShelfMotion.micro, value: isDropTargeted)
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .onTapGesture(perform: onReplaceCover)
                .onHover { isPosterHovered = $0 }
                .help(lang.tr("点击更换封面，或直接拖入图片", "Click to change cover, or drop an image here"))
                .onDrop(of: [.fileURL, .image, .url], isTargeted: $isDropTargeted) { providers in
                    CoverManager.shared.readDroppedImage(from: providers) { source in
                        if let source {
                            store.importCover(source, for: item.id)
                        } else {
                            store.showToast(lang.tr("无法识别拖入的图片", "Could not recognize the dropped image"))
                        }
                    }
                }

                VStack(spacing: 8) {
                    // Clickable Title & Subtitle (inline popover rename)
                    Button {
                        titleEditingItemID = item.id
                        draftTitleZH = item.title
                        draftTitleEN = item.titleEN
                        showTitlePopover = true
                    } label: {
                        VStack(spacing: 3) {
                            Text(shownTitle)
                                .font(.system(size: 16.5, weight: .bold))
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.center)

                            if let subTitle = item.secondaryTitle(in: lang) {
                                Text(subTitle)
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(isTitleHovered ? Color.primary.opacity(0.06) : Color.clear)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .animation(reduceMotion ? nil : ShelfMotion.micro, value: isTitleHovered)
                    .padding(.horizontal, 12)
                    .onHover { isTitleHovered = $0 }
                    .help(lang.tr("点击修改中英文名称", "Click to edit titles"))
                    .popover(isPresented: $showTitlePopover, arrowEdge: .bottom) {
                        titleEditorPopover
                    }

                    // Clickable Category & Tag Pills
                    ShelfFlowLayout(alignment: .center, horizontalSpacing: 6, verticalSpacing: 6) {
                        Button {
                            showCategoryPopover = true
                        } label: {
                            Label(item.category.title(in: lang), systemImage: item.category.systemImage)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(item.category.accentColor)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 3.5)
                                .background(
                                    item.category.accentColor.opacity(isCategoryHovered ? 0.22 : 0.13),
                                    in: Capsule()
                                )
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .animation(reduceMotion ? nil : ShelfMotion.micro, value: isCategoryHovered)
                        .onHover { isCategoryHovered = $0 }
                        .help(lang.tr("点击切换分类", "Click to change category"))
                        .popover(isPresented: $showCategoryPopover, arrowEdge: .bottom) {
                            categoryPickerPopover
                        }

                        if item.tags.isEmpty {
                            Button {
                                showSubtagPopover = true
                            } label: {
                                Label(lang.tr("添加标签", "Add Tags"), systemImage: "tag")
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(isSubtagHovered ? .secondary : .tertiary)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 3.5)
                                    .background(
                                        Color.primary.opacity(isSubtagHovered ? 0.10 : 0.045),
                                        in: Capsule()
                                    )
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .animation(reduceMotion ? nil : ShelfMotion.micro, value: isSubtagHovered)
                            .onHover { isSubtagHovered = $0 }
                            .help(lang.tr("设置标签 (⇧⌘T)", "Edit tags (⇧⌘T)"))
                            .popover(isPresented: $showSubtagPopover, arrowEdge: .bottom) {
                                subtagEditorPopover
                            }
                        } else {
                            ForEach(item.tags, id: \.self) { tag in
                                let localized = MediaCategory.localizedTag(tag, in: lang)
                                let tagHovered = hoveredTagPill == tag
                                Button {
                                    showSubtagPopover = true
                                } label: {
                                    Text(localized)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(tagHovered ? .primary : .secondary)
                                        .lineLimit(1)
                                        .padding(.horizontal, 9)
                                        .padding(.vertical, 3.5)
                                        .background(
                                            Color.primary.opacity(tagHovered ? 0.12 : 0.07),
                                            in: Capsule()
                                        )
                                        .contentShape(Capsule())
                                }
                                .buttonStyle(.plain)
                                .animation(reduceMotion ? nil : ShelfMotion.micro, value: tagHovered)
                                .onHover { inside in
                                    hoveredTagPill = inside ? tag : (hoveredTagPill == tag ? nil : hoveredTagPill)
                                }
                                .help(lang.tr("点击编辑标签 (⇧⌘T) · 右键更多操作", "Click to edit tags (⇧⌘T) · Right-click for more"))
                                .contextMenu {
                                    Button {
                                        store.selectSingleTagFilter(tag, switchToAllIfEmptyInCurrentDestination: false)
                                    } label: {
                                        Label(
                                            lang.tr("按「\(localized)」筛选", "Filter by “\(localized)”"),
                                            systemImage: "line.3.horizontal.decrease.circle"
                                        )
                                    }

                                    Button {
                                        store.toggleItemTag(tag, for: item.id)
                                    } label: {
                                        Label(lang.tr("移除此标签", "Remove Tag"), systemImage: "xmark.circle")
                                    }

                                    Divider()

                                    Button {
                                        TagWindowController.shared.show(store: store)
                                    } label: {
                                        Label(lang.tr("管理标签…", "Manage Tags…"), systemImage: "slider.horizontal.3")
                                    }
                                }
                            }

                            Button {
                                showSubtagPopover = true
                            } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 9.5, weight: .bold))
                                    .foregroundStyle(isSubtagHovered ? .primary : .secondary)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 4)
                                    .background(
                                        Color.primary.opacity(isSubtagHovered ? 0.12 : 0.05),
                                        in: Capsule()
                                    )
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .animation(reduceMotion ? nil : ShelfMotion.micro, value: isSubtagHovered)
                            .onHover { isSubtagHovered = $0 }
                            .help(lang.tr("设置标签 (⇧⌘T)", "Edit tags (⇧⌘T)"))
                            .popover(isPresented: $showSubtagPopover, arrowEdge: .bottom) {
                                subtagEditorPopover
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 24)

            ShelfIconButton(
                systemName: "xmark",
                size: 27,
                iconSize: 10.5,
                helpText: lang.tr("收起详情栏 (Esc)", "Hide Details (Esc)"),
                usesMaterial: true,
                action: onClose
            )
            .padding(12)
        }
    }

    // MARK: - Inline Metadata Popovers

    private var titleEditorPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(lang.tr("中文名称 / 原名", "Chinese / Primary Title"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField(lang.tr("作品名称", "Title"), text: $draftTitleZH)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                    .onSubmit {
                        commitTitleEdit()
                        showTitlePopover = false
                    }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(lang.tr("英文名称（无官翻可留空）", "English Title (Optional)"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField("English Title", text: $draftTitleEN)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                    .onSubmit {
                        commitTitleEdit()
                        showTitlePopover = false
                    }
            }

            HStack {
                Spacer()
                Button(lang.tr("保存", "Save")) {
                    commitTitleEdit()
                    showTitlePopover = false
                }
                .buttonStyle(
                    ShelfButtonStyle(
                        variant: .primary,
                        horizontalPadding: 14,
                        verticalPadding: 5,
                        cornerRadius: 6
                    )
                )
                .font(.system(size: 12, weight: .semibold))
            }
        }
        .padding(14)
        .frame(width: 260)
        .onDisappear {
            commitTitleEdit()
        }
    }

    private var categoryPickerPopover: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(MediaCategory.allCases) { cat in
                let selected = (item.category == cat)
                let hovered = hoveredCategoryOption == cat
                Button {
                    applyCategoryChange(cat)
                    showCategoryPopover = false
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: cat.systemImage)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(selected ? .white : cat.accentColor)
                            .frame(width: 16)
                        Text(cat.title(in: lang))
                            .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                        Spacer()
                        if selected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10.5, weight: .bold))
                        }
                    }
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(selected ? Color.accentColor : (hovered ? Color.primary.opacity(0.07) : Color.clear))
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .animation(reduceMotion ? nil : ShelfMotion.micro, value: hovered)
                .onHover { inside in
                    hoveredCategoryOption = inside ? cat : (hoveredCategoryOption == cat ? nil : hoveredCategoryOption)
                }
            }
        }
        .padding(8)
        .frame(width: 156)
    }

    private var subtagEditorPopover: some View {
        TagPickerContentView(
            store: store,
            itemID: item.id,
            language: lang
        ) {
            showSubtagPopover = false
        }
        .frame(width: 265)
    }

    private func commitTitleEdit() {
        guard let targetID = titleEditingItemID else { return }
        titleEditingItemID = nil
        guard let target = store.item(withID: targetID) else { return }

        let cleanZH = draftTitleZH.trimmed
        let cleanEN = draftTitleEN.trimmed
        guard !cleanZH.isEmpty || !cleanEN.isEmpty else { return }
        let finalZH = cleanZH.isEmpty ? cleanEN : cleanZH
        guard finalZH != target.title || cleanEN != target.titleEN else { return }

        var updated = target
        updated.title = finalZH
        updated.titleEN = cleanEN
        updated.isSample = false
        store.updateItem(updated, originalCoverFileName: target.coverFileName)
    }

    private func applyCategoryChange(_ newCategory: MediaCategory) {
        guard newCategory != item.category else { return }
        var updated = item
        updated.category = newCategory
        updated.isSample = false
        store.updateItem(updated, originalCoverFileName: item.coverFileName)
    }

    // MARK: - Status, Unified Metadata Card, Notes & Quiet Footer

    private var statusSwitcherSection: some View {
        let isDark = colorScheme == .dark
        return LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 3),
                GridItem(.flexible(), spacing: 3)
            ],
            spacing: 3
        ) {
            ForEach(TrackingStatus.filterOrder) { st in
                let isSelected = item.status == st
                let isHovered = hoveredStatus == st
                Button {
                    store.updateStatus(for: item.id, to: st)
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(st.tintColor)
                            .frame(width: 6.5, height: 6.5)
                            .opacity(isSelected ? 1.0 : (isHovered ? 0.90 : 0.72))
                        Text(item.category.statusLabel(for: st, in: lang))
                            .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(isHovered ? 0.90 : 0.68))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                                .fill(Color(nsColor: .controlBackgroundColor))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                                        .fill(st.tintColor.opacity(isDark ? 0.14 : 0.09))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                                        .strokeBorder(st.tintColor.opacity(isDark ? 0.42 : 0.34), lineWidth: 0.8)
                                )
                                .shadow(color: .black.opacity(isDark ? 0.24 : 0.07), radius: 2.5, x: 0, y: 1)
                                .matchedGeometryEffect(id: "detailStatus", in: statusNamespace)
                        } else if isHovered {
                            RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                                .fill(Color.primary.opacity(isDark ? 0.065 : 0.045))
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 7.5, style: .continuous))
                }
                .buttonStyle(.plain)
                .animation(reduceMotion ? nil : ShelfMotion.micro, value: isHovered)
                .onHover { inside in
                    hoveredStatus = inside ? st : (hoveredStatus == st ? nil : hoveredStatus)
                }
            }
        }
        .animation(reduceMotion ? nil : ShelfMotion.control, value: item.status)
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(isDark ? 0.07 : 0.048))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(isDark ? 0.10 : 0.075), lineWidth: 0.75)
        )
    }

    private var metadataCardSection: some View {
        let isDark = colorScheme == .dark
        let span = item.effectiveTimelineSpan()

        return VStack(spacing: 0) {
            HStack {
                Text(lang.tr("评分", "Rating"))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                StarRatingView(
                    rating: Binding(
                        get: { item.rating },
                        set: { store.updateRating(for: item.id, rating: $0) }
                    ),
                    starSize: 15.5,
                    spacing: 5,
                    interactive: true
                )

                if item.rating > 0 {
                    Text(lang == .zh ? "\(item.rating) 星" : "\(item.rating)★")
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, alignment: .trailing)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            ShelfHairline()
                .padding(.horizontal, 12)

            Button {
                timelineEditingItemID = item.id
                draftHasStartDate = item.startedAt != nil
                draftStartDate = item.startedAt ?? item.finishedAt ?? Date()
                draftHasFinishDate = item.finishedAt != nil
                draftFinishDate = item.finishedAt ?? item.startedAt ?? Date()
                showTimelinePopover = true
            } label: {
                HStack(spacing: 8) {
                    Text(lang.tr("时间", "Dates"))
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 6)

                    if let span {
                        let cal = TimelineLayoutModel.gregorianCalendar
                        let sDay = cal.startOfDay(for: span.start)
                        let eDay = cal.startOfDay(for: span.end)
                        let days = max(1, (cal.dateComponents([.day], from: sDay, to: eDay).day ?? 0) + 1)

                        VStack(alignment: .trailing, spacing: 1.5) {
                            Text(
                                TimelineDateFormatter.spanText(
                                    start: sDay,
                                    end: eDay,
                                    isOngoing: span.isOngoing,
                                    durationDays: days,
                                    language: lang
                                )
                            )
                            .font(.system(size: 11.5, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                            Text(TimelineDateFormatter.durationText(days: days, isOngoing: span.isOngoing, language: lang))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: "calendar.badge.plus")
                                .font(.system(size: 11))
                            Text(lang.tr("设置日期…", "Set dates…"))
                                .font(.system(size: 11.5))
                        }
                        .foregroundStyle(isTimelineHovered ? .secondary : .tertiary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.primary.opacity(isTimelineHovered ? 0.045 : 0.0))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .animation(reduceMotion ? nil : ShelfMotion.micro, value: isTimelineHovered)
            .onHover { isTimelineHovered = $0 }
            .help(lang.tr("点击设置开始与结束日期（用于时间线视图）", "Click to set start and finish dates for Timeline view"))
            .popover(isPresented: $showTimelinePopover, arrowEdge: .leading) {
                timelineEditorPopover
            }
        }
        .background(Color.primary.opacity(isDark ? 0.05 : 0.038), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.primary.opacity(isDark ? 0.09 : 0.075), lineWidth: 0.75)
        )
    }

    private var timelineEditorPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(lang.tr("时间线日期", "Timeline Dates"))
                    .font(.system(size: 13, weight: .bold))
                Spacer()
                if draftHasStartDate || draftHasFinishDate {
                    Button(lang.tr("清除", "Clear")) {
                        draftHasStartDate = false
                        draftHasFinishDate = false
                        if let targetID = timelineEditingItemID {
                            store.updateTimelineDates(for: targetID, startedAt: nil, finishedAt: nil)
                        }
                    }
                    .buttonStyle(ShelfButtonStyle(variant: .subtle, horizontalPadding: 7, verticalPadding: 3, cornerRadius: 5))
                    .font(.system(size: 11))
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Toggle(lang.tr("开始日期", "Start Date"), isOn: $draftHasStartDate)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Button(lang.tr("今天", "Today")) {
                        draftHasStartDate = true
                        draftStartDate = Date()
                    }
                    .buttonStyle(ShelfButtonStyle(variant: .subtle, horizontalPadding: 6, verticalPadding: 2, cornerRadius: 5))
                    .font(.system(size: 10.5))
                }

                if draftHasStartDate {
                    DatePicker(
                        "",
                        selection: $draftStartDate,
                        displayedComponents: .date
                    )
                    .labelsHidden()
                    .datePickerStyle(.field)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Toggle(lang.tr("结束日期", "Finish Date"), isOn: $draftHasFinishDate)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Button(lang.tr("今天", "Today")) {
                        draftHasFinishDate = true
                        draftFinishDate = Date()
                    }
                    .buttonStyle(ShelfButtonStyle(variant: .subtle, horizontalPadding: 6, verticalPadding: 2, cornerRadius: 5))
                    .font(.system(size: 10.5))
                }

                if draftHasFinishDate {
                    DatePicker(
                        "",
                        selection: $draftFinishDate,
                        displayedComponents: .date
                    )
                    .labelsHidden()
                    .datePickerStyle(.field)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else if item.status == .active && draftHasStartDate {
                    Text(lang.tr("留空时，进行中的作品会在时间线上持续延伸至今天。", "Leave empty so active items extend to today on the timeline."))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button(lang.tr("保存", "Save")) {
                    commitTimelineDates()
                    showTimelinePopover = false
                }
                .buttonStyle(
                    ShelfButtonStyle(
                        variant: .primary,
                        horizontalPadding: 14,
                        verticalPadding: 5,
                        cornerRadius: 6
                    )
                )
                .font(.system(size: 12, weight: .semibold))
            }
        }
        .padding(14)
        .frame(width: 256)
        .animation(reduceMotion ? nil : ShelfMotion.control, value: draftHasStartDate)
        .animation(reduceMotion ? nil : ShelfMotion.control, value: draftHasFinishDate)
        .onDisappear {
            commitTimelineDates()
        }
    }

    private func commitTimelineDates() {
        guard let targetID = timelineEditingItemID else { return }
        timelineEditingItemID = nil
        let cal = TimelineLayoutModel.gregorianCalendar
        let s = draftHasStartDate ? cal.startOfDay(for: draftStartDate) : nil
        let f = draftHasFinishDate ? cal.startOfDay(for: draftFinishDate) : nil
        store.updateTimelineDates(for: targetID, startedAt: s, finishedAt: f)
    }

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(lang.tr("备注与评价", "Notes & Review"), systemImage: "square.and.pencil")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !draftNotes.isEmpty {
                    Text(lang == .zh ? "\(draftNotes.count) 字" : "\(draftNotes.count) chars")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }

            ShelfNotesEditor(
                text: $draftNotes,
                placeholder: lang.tr("写点评价或备注…", "Write notes or thoughts…"),
                fontSize: 13,
                lineSpacing: 4,
                minHeight: 145,
                fillOpacity: 0.05,
                borderOpacity: 0.10,
                cornerRadius: 10
            )
            .onChange(of: draftNotes) { _, newValue in
                store.updateNotes(for: item.id, notes: newValue)
            }
        }
    }

    private var metadataFooter: some View {
        let createdStr = Self.dateFormatter.string(from: item.createdAt)
        let updatedStr = Self.dateFormatter.string(from: item.updatedAt)

        return VStack(spacing: 10) {
            ShelfHairline()

            HStack(spacing: 8) {
                Group {
                    if updatedStr != createdStr {
                        Text(
                            lang.tr(
                                "记录于 \(createdStr) · 更新于 \(updatedStr)",
                                "Added \(createdStr) · Updated \(updatedStr)"
                            )
                        )
                    } else {
                        Text(lang.tr("记录于 \(createdStr)", "Added \(createdStr)"))
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)

                Spacer(minLength: 4)

                Button {
                    showDeleteConfirm = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isDeleteHovered ? ShelfTheme.destructiveRed : Color.secondary.opacity(0.70))
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(isDeleteHovered ? Color.red.opacity(0.12) : Color.clear)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .animation(reduceMotion ? nil : ShelfMotion.micro, value: isDeleteHovered)
                .onHover { isDeleteHovered = $0 }
                .help(lang.tr("删除该作品", "Delete Item"))
            }
        }
        .padding(.top, 4)
    }
}
