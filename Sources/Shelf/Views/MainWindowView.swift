import SwiftUI

struct MainWindowView: View {
    @EnvironmentObject private var store: LibraryStore
    @Binding var showAddSheet: Bool
    @AppStorage("shelf.posterScale") private var posterScale: Double = 1.0

    @State private var editingItem: MediaItem? = nil
    @State private var coverReplacingItem: MediaItem? = nil
    @State private var quickAddPresetStatus: TrackingStatus? = nil
    @State private var collapsedShelves: Set<TrackingStatus> = []

    private var lang: AppLanguage { store.language }

    private var activeCategory: MediaCategory? {
        store.selectedDestination.activeCategory
    }

    private var isStatusLockedBySidebar: Bool {
        store.selectedDestination.isStatusLocked
    }

    private var cardMinWidth: CGFloat {
        round(148 * posterScale)
    }

    private var cardMaxWidth: CGFloat {
        round(186 * posterScale)
    }

    private var horizontalSpacing: CGFloat {
        round(20 * max(0.85, posterScale * 0.95))
    }

    private var verticalSpacing: CGFloat {
        round(24 * max(0.88, posterScale * 0.95))
    }

    var body: some View {
        let visibleItems = store.filteredItems()

        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 195, ideal: 215, max: 260)
        } detail: {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    shelfTopControlBar
                    Divider()

                    ZStack(alignment: .bottom) {
                        libraryCanvas(visibleItems: visibleItems)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                        if let toast = store.toastMessage {
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text(toast)
                                    .font(.system(size: 12.5, weight: .medium))
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .background(
                                Capsule()
                                    .fill(Color(nsColor: .controlBackgroundColor))
                            )
                            .overlay(
                                Capsule()
                                    .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.8)
                            )
                            .shadow(color: .black.opacity(0.22), radius: 10, x: 0, y: 4)
                            .padding(.bottom, 14)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .allowsHitTesting(false)
                        }
                    }

                    Divider()
                    bottomStatusBar(visibleCount: visibleItems.count)
                }

                if let selectedItem = store.selectedItem {
                    Divider()
                    ItemDetailPanel(
                        item: selectedItem,
                        onReplaceCover: {
                            coverReplacingItem = selectedItem
                        },
                        onEditTapped: {
                            editingItem = selectedItem
                        },
                        onClose: {
                            withAnimation(.snappy(duration: 0.20)) {
                                store.selectedItemID = nil
                            }
                        }
                    )
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .animation(.snappy(duration: 0.20), value: store.selectedItemID != nil)
            .navigationTitle(store.selectedDestination.title(in: lang))
            .navigationSubtitle(itemCountText(visibleItems.count, compact: true))
            .searchable(
                text: $store.searchText,
                placement: .toolbar,
                prompt: lang.tr("搜索名称、标签或备注…", "Search titles, tags, or notes…")
            )
            .toolbar {
                toolbarContent
            }
        }
        .sheet(isPresented: $showAddSheet) {
            ItemEditorSheet(
                existingItem: nil,
                defaultCategory: defaultCategoryForNewItem,
                defaultStatus: quickAddPresetStatus ?? defaultStatusForNewItem,
                language: lang
            ) { newItem in
                let created = store.addItem(newItem)
                store.selectedItemID = created.id
            }
        }
        .sheet(item: $editingItem) { itemToEdit in
            ItemEditorSheet(existingItem: itemToEdit, language: lang) { updated in
                store.updateItem(updated)
            }
        }
        .sheet(item: $coverReplacingItem) { itemForCover in
            CoverPickerSheet(
                itemTitle: itemForCover.displayTitle(in: lang),
                category: itemForCover.category,
                subtag: itemForCover.subtag,
                initialCoverFileName: itemForCover.coverFileName,
                paletteSeed: itemForCover.paletteSeed,
                language: lang
            ) { newCoverFileName in
                store.updateCover(for: itemForCover.id, newCoverFileName: newCoverFileName)
            }
        }
    }

    private func itemCountText(_ count: Int, compact: Bool) -> String {
        if lang == .zh {
            return compact ? "\(count) 项" : "共 \(count) 项"
        } else {
            return count == 1 ? "1 item" : "\(count) items"
        }
    }

    // MARK: - Top Control Bar

    private var shelfTopControlBar: some View {
        HStack(spacing: 12) {
            if !isStatusLockedBySidebar {
                ShelfSegmentedControl(
                    segments: statusSegments,
                    selection: $store.statusFilter,
                    verticalPadding: 5.5
                )
                .frame(maxWidth: 500)
            } else {
                ShelfSegmentedControl(
                    segments: [
                        .init(value: Optional<MediaCategory>.none, title: lang.tr("全部", "All"))
                    ] + MediaCategory.allCases.map { cat in
                        .init(value: Optional(cat), title: cat.title(in: lang), icon: cat.systemImage)
                    },
                    selection: $store.categoryFilter,
                    verticalPadding: 5.5
                )
                .frame(maxWidth: 380)
            }

            Spacer(minLength: 8)

            ShelfSortControl(
                sortField: store.sortField,
                sortAscending: store.sortAscending,
                language: lang,
                onSelectField: { field in
                    withAnimation(.snappy(duration: 0.18)) {
                        store.selectSortField(field)
                    }
                },
                onSetAscending: { asc in
                    withAnimation(.snappy(duration: 0.18)) {
                        store.sortAscending = asc
                    }
                }
            )

            Button {
                quickAddPresetStatus = nil
                showAddSheet = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                        .font(.system(size: 11.5, weight: .bold))
                    Text(lang.tr("添加作品", "Add Item"))
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                }
            }
            .buttonStyle(
                ShelfButtonStyle(
                    variant: .primary,
                    horizontalPadding: 13,
                    verticalPadding: 6.5,
                    cornerRadius: 8
                )
            )
            .fixedSize()
            .help(lang.tr("添加新作品 (⌘N)", "Add new item (⌘N)"))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var statusSegments: [ShelfSegmentedControl<StatusFilterOption>.Segment] {
        var list: [ShelfSegmentedControl<StatusFilterOption>.Segment] = [
            .init(value: .allShelves, title: lang.tr("分栏", "Shelves"))
        ]
        for st in TrackingStatus.filterOrder {
            list.append(
                .init(
                    value: .single(st),
                    title: st.localizedTitle(in: activeCategory, lang: lang),
                    dotColor: st.tintColor
                )
            )
        }
        return list
    }

    // MARK: - Library Canvas

    private func libraryCanvas(visibleItems: [MediaItem]) -> some View {
        let tags = activeCategory != nil ? store.availableSubtagsInCurrentView : []
        let isSearching = !store.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        return ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let cat = activeCategory, (tags.count > 1 || store.subtagFilter != nil) {
                    subtagFilterBar(category: cat, tags: tags)
                }

                if visibleItems.isEmpty {
                    emptyStateView
                        .padding(.top, 64)
                } else if !isStatusLockedBySidebar && store.statusFilter == .allShelves && !isSearching {
                    groupedShelvesView(visibleItems: visibleItems)
                } else {
                    posterGrid(items: visibleItems, showStatusBadges: !isStatusLockedBySidebar)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 36)
        }
    }

    private func subtagFilterBar(category: MediaCategory, tags: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Text(lang == .zh ? "\(category.subtagShortLabel(in: lang))：" : "\(category.subtagShortLabel(in: lang)):")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)

                ShelfChipButton(title: lang.tr("全部", "All"), isSelected: store.subtagFilter == nil) {
                    store.subtagFilter = nil
                }

                ForEach(tags, id: \.self) { tag in
                    ShelfChipButton(
                        title: MediaCategory.localizedSubtag(tag, in: lang),
                        isSelected: store.subtagFilter == tag
                    ) {
                        store.subtagFilter = (store.subtagFilter == tag) ? nil : tag
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - Grouped Shelves

    private func groupedShelvesView(visibleItems: [MediaItem]) -> some View {
        let grouped = Dictionary(grouping: visibleItems, by: \.status)

        return VStack(alignment: .leading, spacing: 32) {
            ForEach(TrackingStatus.shelfOrder) { status in
                if let shelfItems = grouped[status], !shelfItems.isEmpty {
                    let isCollapsed = collapsedShelves.contains(status)
                    let shelfLabel = status.localizedTitle(in: activeCategory, lang: lang)
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 10) {
                            ShelfHeaderToggleButton(
                                title: shelfLabel,
                                count: shelfItems.count,
                                dotColor: status.tintColor,
                                isCollapsed: isCollapsed
                            ) {
                                withAnimation(.snappy(duration: 0.20)) {
                                    if isCollapsed {
                                        collapsedShelves.remove(status)
                                    } else {
                                        collapsedShelves.insert(status)
                                    }
                                }
                            }

                            Rectangle()
                                .fill(Color.primary.opacity(0.09))
                                .frame(height: 1)

                            ShelfIconButton(
                                systemName: "plus",
                                size: 24,
                                iconSize: 11,
                                helpText: lang.tr("添加到「\(shelfLabel)」", "Add to \(shelfLabel)")
                            ) {
                                quickAddPresetStatus = status
                                showAddSheet = true
                            }
                        }

                        if !isCollapsed {
                            posterGrid(items: shelfItems, showStatusBadges: false)
                        }
                    }
                }
            }
        }
    }

    private func posterGrid(items: [MediaItem], showStatusBadges: Bool) -> some View {
        LazyVGrid(
            columns: [
                GridItem(.adaptive(minimum: cardMinWidth, maximum: cardMaxWidth), spacing: horizontalSpacing)
            ],
            alignment: .leading,
            spacing: verticalSpacing
        ) {
            ForEach(items) { item in
                PosterCardView(
                    item: item,
                    isSelected: store.selectedItemID == item.id,
                    showStatusBadge: showStatusBadges,
                    onSelect: {
                        if store.selectedItemID != item.id {
                            store.selectedItemID = item.id
                        }
                    },
                    onDoubleClickEdit: {
                        editingItem = item
                    },
                    onReplaceCover: {
                        coverReplacingItem = item
                    }
                )
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 14) {
            Image(systemName: activeCategory?.systemImage ?? "books.vertical")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.secondary.opacity(0.7))

            Text(
                store.searchText.isEmpty
                    ? lang.tr("暂无记录", "No Items Yet")
                    : lang.tr("没有找到匹配项", "No Matching Items")
            )
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.primary.opacity(0.85))

            Text(
                store.searchText.isEmpty
                    ? lang.tr("点击下方按钮或右上角「添加作品」开始记录。", "Click below or “Add Item” in the top-right to start tracking.")
                    : lang.tr("试试换个关键词，或清除筛选条件。", "Try another keyword or clear your active filters.")
            )
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 380)

            if store.searchText.isEmpty {
                HStack(spacing: 12) {
                    Button {
                        quickAddPresetStatus = nil
                        showAddSheet = true
                    } label: {
                        Label(lang.tr("添加作品", "Add Item"), systemImage: "plus")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .buttonStyle(
                        ShelfButtonStyle(
                            variant: .primary,
                            horizontalPadding: 18,
                            verticalPadding: 8,
                            cornerRadius: 9
                        )
                    )

                    if store.items.isEmpty {
                        Button {
                            store.restoreSampleItems()
                        } label: {
                            Label(lang.tr("载入示例数据", "Load Sample Data"), systemImage: "sparkles")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .buttonStyle(
                            ShelfButtonStyle(
                                variant: .secondary,
                                horizontalPadding: 16,
                                verticalPadding: 8,
                                cornerRadius: 9
                            )
                        )
                    }
                }
                .padding(.top, 6)
            } else {
                Button(lang.tr("清除搜索", "Clear Search")) {
                    store.searchText = ""
                }
                .buttonStyle(
                    ShelfButtonStyle(
                        variant: .secondary,
                        horizontalPadding: 16,
                        verticalPadding: 7,
                        cornerRadius: 8
                    )
                )
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Bottom Status & Poster Zoom Bar

    private func bottomStatusBar(visibleCount: Int) -> some View {
        HStack(spacing: 12) {
            Text(itemCountText(visibleCount, compact: false))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Spacer()

            HStack(spacing: 8) {
                Button {
                    posterScale = max(0.78, posterScale - 0.08)
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(lang.tr("缩小海报 (⌘-)", "Zoom out (⌘-)"))

                Slider(value: $posterScale, in: 0.78...1.36)
                    .frame(width: 96)
                    .controlSize(.small)
                    .help(lang.tr("拖动调整海报尺寸", "Adjust poster size"))

                Button {
                    posterScale = min(1.36, posterScale + 0.08)
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(lang.tr("放大海报 (⌘+)", "Zoom in (⌘+)"))
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 30)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Window Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if store.selectedItem != nil {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    withAnimation(.snappy(duration: 0.20)) {
                        store.selectedItemID = nil
                    }
                } label: {
                    Label(lang.tr("收起详情栏", "Hide Details"), systemImage: "sidebar.right")
                }
                .help(lang.tr("收起右侧详情面板", "Hide right details panel"))
            }
        }
    }

    private var defaultCategoryForNewItem: MediaCategory {
        if case .category(let cat) = store.selectedDestination {
            return cat
        }
        return .game
    }

    private var defaultStatusForNewItem: TrackingStatus {
        if case .status(let st) = store.selectedDestination {
            return st
        }
        if case .single(let st) = store.statusFilter {
            return st
        }
        return .active
    }
}

private struct ShelfHeaderToggleButton: View {
    let title: String
    let count: Int
    let dotColor: Color
    let isCollapsed: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)

                Circle()
                    .fill(dotColor)
                    .frame(width: 8, height: 8)

                Text(title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.primary.opacity(0.92))

                Text("\(count)")
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1.5)
                    .background(Color.primary.opacity(0.08), in: Capsule())
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(0.06) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
