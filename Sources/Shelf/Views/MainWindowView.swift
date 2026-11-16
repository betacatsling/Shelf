import SwiftUI

struct MainWindowView: View {
    @Environment(LibraryStore.self) private var store
    @Binding var showAddSheet: Bool
    @AppStorage("shelf.posterScale") private var posterScale: Double = 1.0
    @AppStorage("shelf.collapsedShelves") private var collapsedShelvesRaw: String = ""

    @State private var editingItem: MediaItem? = nil
    @State private var coverReplacingItem: MediaItem? = nil
    @State private var quickAddPresetStatus: TrackingStatus? = nil
    @State private var preparedLibrary: (LibraryQuery.Request, LibraryProjection)?
    @State private var draggedPosterScale: Double?

    private var lang: AppLanguage { store.language }

    private var activeCategory: MediaCategory? {
        store.selectedDestination.activeCategory
    }

    private var collapsedShelves: Set<TrackingStatus> {
        Set(
            collapsedShelvesRaw
                .split(separator: ",")
                .compactMap { TrackingStatus(rawValue: String($0)) }
        )
    }

    private func toggleShelfCollapse(_ status: TrackingStatus) {
        var current = collapsedShelves
        if current.contains(status) {
            current.remove(status)
        } else {
            current.insert(status)
        }
        collapsedShelvesRaw = TrackingStatus.shelfOrder
            .filter { current.contains($0) }
            .map(\.rawValue)
            .joined(separator: ",")
    }

    private func scrollResetToken(for options: LibraryQuery.Options) -> Int {
        var hasher = Hasher()
        hasher.combine(options.destination)
        hasher.combine(options.status)
        hasher.combine(options.tagGroups)
        hasher.combine(options.untaggedOnly)
        return hasher.finalize()
    }

    var body: some View {
        let request = store.projectionRequest
        let backgroundRequest = store.shouldProjectInBackground ? request : nil
        let prepared = backgroundRequest == nil ? nil : preparedLibrary
        let library = backgroundRequest == nil ? store.projection() : (prepared?.1 ?? .empty)
        let options = prepared?.0.options ?? request.options
        let showsDetails = store.selectedItemID.flatMap(store.item(withID:)) != nil

        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 195, ideal: 215, max: 260)
        } detail: {
            GeometryReader { workspace in
                VStack(alignment: .leading, spacing: 0) {
                    shelfTopControlBar(counts: library.statusCounts)
                    Divider()

                    libraryCanvas(library, options: options, waiting: backgroundRequest != nil && prepared == nil,
                                  posterWidthBasis: workspace.size.width)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay(alignment: .bottom) { LibraryToastView() }

                    Divider()
                    bottomStatusBar(visibleCount: library.count)
                }
                .modifier(DetailDrawerLayout(workspaceWidth: workspace.size.width,
                                             initialPosterID: library.sections.first?.items.first?.id,
                                             onReplaceCover: { coverReplacingItem = $0 }))
                .overlay {
                    if store.isQuickFindPresented {
                        QuickFindOverlay(
                            store: store,
                            library: library,
                            language: lang
                        ) {
                            store.isQuickFindPresented = false
                        }
                        .transition(.opacity)
                    } else if let pickerItemID = store.tagPickerItemID,
                              store.item(withID: pickerItemID) != nil {
                        TagPickerOverlay(
                            store: store,
                            itemID: pickerItemID,
                            language: lang
                        ) {
                            store.tagPickerItemID = nil
                        }
                        .transition(.opacity)
                    }
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationTitle(store.selectedDestination.title(in: lang))
            .navigationSubtitle(itemCountText(library.count, compact: true))
            .toolbar {
                toolbarContent(showsDetails: showsDetails, library: library)
            }
        }
        .sheet(isPresented: $showAddSheet) {
            ItemEditorSheet(
                store: store,
                existingItem: nil,
                defaultCategory: defaultCategoryForNewItem,
                defaultStatus: quickAddPresetStatus ?? defaultStatusForNewItem,
                defaultTags: store.activeFilterTags,
                language: lang
            ) { newItem in
                let created = store.addItem(newItem)
                store.selectedItemID = created.id
            }
        }
        .sheet(item: $editingItem) { itemToEdit in
            ItemEditorSheet(store: store, existingItem: itemToEdit, language: lang) { updated in
                store.updateItem(updated, originalCoverFileName: itemToEdit.coverFileName)
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
        .task(id: backgroundRequest) {
            guard let backgroundRequest else {
                preparedLibrary = nil
                return
            }
            if let preparedLibrary, preparedLibrary.0.options.text != backgroundRequest.options.text {
                try? await Task.sleep(for: .milliseconds(40))
            }
            guard !Task.isCancelled, let result = await store.backgroundProjection(for: backgroundRequest),
                  !Task.isCancelled, store.projectionRequest == backgroundRequest else { return }
            preparedLibrary = (backgroundRequest, result)
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

    private func shelfTopControlBar(counts: [TrackingStatus: Int]) -> some View {
        @Bindable var store = store
        return HStack(spacing: 12) {
            ViewThatFits(in: .horizontal) {
                ShelfSegmentedControl(
                    segments: statusSegments(counts: counts, compactLabels: false),
                    selection: $store.statusFilter,
                    verticalPadding: 5.5,
                    equalWidthSegments: false
                )

                ShelfSegmentedControl(
                    segments: statusSegments(counts: counts, compactLabels: true),
                    selection: $store.statusFilter,
                    verticalPadding: 5.5,
                    equalWidthSegments: false
                )

                ShelfSegmentedControl(
                    segments: statusSegments(counts: nil, compactLabels: false),
                    selection: $store.statusFilter,
                    verticalPadding: 5.5,
                    equalWidthSegments: false
                )

                ShelfSegmentedControl(
                    segments: statusSegments(counts: nil, compactLabels: true),
                    selection: $store.statusFilter,
                    verticalPadding: 5.5,
                    equalWidthSegments: false
                )

                statusFilterMenu(counts: counts)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            ShelfSortControl(
                sortField: store.sortField,
                sortAscending: store.sortAscending,
                language: lang,
                onSelectField: { store.selectSortField($0) },
                onSetAscending: { store.sortAscending = $0 }
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
            .disabled(!store.isReady)
            .help(lang.tr("添加新作品 (⌘N)", "Add new item (⌘N)"))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func statusFilterMenu(counts: [TrackingStatus: Int]) -> some View {
        let segments = statusSegments(counts: counts, compactLabels: false)
        return Menu {
            ForEach(segments) { segment in
                let title = segment.count.map { "\(segment.title) (\($0))" } ?? segment.title
                Button {
                    store.statusFilter = segment.value
                } label: {
                    if store.statusFilter == segment.value {
                        Label(title, systemImage: "checkmark")
                    } else {
                        Text(title)
                    }
                }
            }
        } label: {
            Label(lang.tr("按状态筛选", "Filter by Status"), systemImage: "line.3.horizontal.decrease")
                .labelStyle(.iconOnly)
        }
        .controlSize(.small)
        .fixedSize()
        .accessibilityValue(segments.first { $0.value == store.statusFilter }?.title ?? "")
        .help(lang.tr("按状态筛选", "Filter by Status"))
    }

    private func statusSegments(
        counts: [TrackingStatus: Int]?,
        compactLabels: Bool
    ) -> [ShelfSegmentedControl<StatusFilterOption>.Segment] {
        var list: [ShelfSegmentedControl<StatusFilterOption>.Segment] = [
            .init(value: .allShelves, title: lang.tr("分栏", "Shelves"))
        ]
        for st in TrackingStatus.filterOrder {
            let label: String
            if compactLabels && lang == .en && activeCategory == nil && st == .active {
                label = "Active"
            } else {
                label = st.localizedTitle(in: activeCategory, lang: lang)
            }
            list.append(
                .init(
                    value: .single(st),
                    title: label,
                    dotColor: st.tintColor,
                    count: counts.map { $0[st, default: 0] }
                )
            )
        }
        return list
    }

    // MARK: - Library Canvas

    private func libraryCanvas(_ library: LibraryProjection, options: LibraryQuery.Options, waiting: Bool,
                               posterWidthBasis: CGFloat) -> some View {
        VStack(spacing: 0) {
            if store.hasActiveFilter {
                activeFilterBar(library: library)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 7)
                Divider()
            }

            if store.isLoading || waiting {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.loadFailed {
                Text(lang.tr("无法读取作品库文件", "Could not read the library file"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if library.count == 0 {
                Spacer(minLength: 0)
                emptyStateView
                Spacer(minLength: 0)
            } else {
                NativePosterGrid(
                    sections: library.sections,
                    collapsedShelves: collapsedShelves,
                    selectedItemID: store.selectedItemID,
                    showStatusBadges: library.showStatusBadges,
                    posterScale: draggedPosterScale ?? posterScale,
                    posterWidthBasis: posterWidthBasis,
                    language: options.language,
                    scrollResetToken: scrollResetToken(for: options),
                    onSelectItem: { id in
                        store.selectedItemID = store.selectedItemID == id ? nil : id
                    },
                    onEnsureSelectItem: { id in
                        if store.selectedItemID != id { store.selectedItemID = id }
                    },
                    onDeselectAll: {
                        if store.selectedItemID != nil {
                            store.selectedItemID = nil
                        } else if store.hasActiveFilter {
                            store.clearSearch()
                        }
                    },
                    onDoubleClickEdit: { id in
                        editingItem = store.item(withID: id)
                    },
                    onRequestEditTags: { id in
                        store.selectedItemID = id
                        store.tagPickerItemID = id
                    },
                    onRequestReplaceCover: { id in
                        coverReplacingItem = store.item(withID: id)
                    },
                    onToggleSectionCollapse: { status in
                        toggleShelfCollapse(status)
                    },
                    onQuickAddInSection: { status in
                        quickAddPresetStatus = status
                        showAddSheet = true
                    },
                    onChangeStatus: { id, status in
                        store.updateStatus(for: id, to: status)
                    },
                    onChangeRating: { id, stars in
                        store.updateRating(for: id, rating: stars)
                    },
                    onUpdateCoverFileName: { id, newCoverFile in
                        store.updateCover(for: id, newCoverFileName: newCoverFile)
                    },
                    onImportCover: { id, source in
                        store.importCover(source, for: id)
                    },
                    onDeleteItem: { id in
                        store.deleteItem(id: id)
                    },
                    onShowToast: { msg in
                        store.showToast(msg)
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var emptyStateView: some View {
        let hasActiveSearch = store.hasActiveFilter
        return VStack(spacing: 14) {
            Image(systemName: activeCategory?.systemImage ?? "books.vertical")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.secondary.opacity(0.7))

            Text(
                !hasActiveSearch
                    ? lang.tr("暂无记录", "No Items Yet")
                    : lang.tr("没有找到匹配项", "No Matching Items")
            )
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.primary.opacity(0.85))

            Text(
                !hasActiveSearch
                    ? lang.tr("点击下方按钮或右上角「添加作品」开始记录。", "Click below or “Add Item” in the top-right to start tracking.")
                    : lang.tr("试试换个关键词，或清除筛选条件。", "Try another keyword or clear your active filters.")
            )
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 380)

            if !hasActiveSearch {
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

                    if store.isEmpty {
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
                    store.clearSearch()
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

                Slider(value: Binding(
                    get: { draggedPosterScale ?? posterScale },
                    set: { value in
                        if draggedPosterScale != nil { draggedPosterScale = value }
                        else { posterScale = value }
                    }
                ), in: 0.78...1.36, onEditingChanged: { editing in
                    if editing {
                        draggedPosterScale = posterScale
                    } else if let value = draggedPosterScale {
                        posterScale = value
                        draggedPosterScale = nil
                    }
                })
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

    // MARK: - Active-Only Things 3 Filter Bar

    private func activeFilterBar(library: LibraryProjection) -> some View {
        let trimmedQuery = store.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let suggestions = narrowingTags(for: library)

        return HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if store.filterUntaggedOnly {
                        activeFilterPill(
                            icon: "tag.slash",
                            title: lang.tr("无标签", "No Tag"),
                            isAccent: true
                        ) {
                            store.filterUntaggedOnly = false
                        }
                    }

                    ForEach(store.searchTokens) { token in
                        let ancestors = store.tagAncestors(of: token.tag)
                        let localized = MediaCategory.localizedTag(token.tag, in: lang)
                        let label = ancestors.isEmpty
                            ? localized
                            : "\(TagCatalog.formattedBreadcrumb(ancestors: ancestors, language: lang)) › \(localized)"
                        activeFilterPill(
                            icon: "tag.fill",
                            title: label,
                            isAccent: true
                        ) {
                            store.toggleSearchTag(token.tag)
                        }
                    }

                    if !trimmedQuery.isEmpty {
                        activeFilterPill(
                            icon: "magnifyingglass",
                            title: "“\(trimmedQuery)”",
                            isAccent: false
                        ) {
                            store.searchText = ""
                        }
                    }

                    if !suggestions.isEmpty {
                        Text("·")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 2)

                        ForEach(suggestions, id: \.self) { tag in
                            Button {
                                store.refineTagFilter(with: tag)
                            } label: {
                                Text(MediaCategory.localizedTag(tag, in: lang))
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 3.5)
                                    .background(Color.primary.opacity(0.055), in: Capsule())
                                    .overlay(
                                        Capsule()
                                            .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.7)
                                    )
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.vertical, 1)
            }

            Button(lang.tr("清除", "Clear")) {
                store.clearSearch()
            }
            .buttonStyle(
                ShelfButtonStyle(
                    variant: .subtle,
                    horizontalPadding: 8,
                    verticalPadding: 3,
                    cornerRadius: 6
                )
            )
            .font(.system(size: 11.5, weight: .medium))
            .help(lang.tr("清除所有筛选 (⌃Esc)", "Clear all filters (⌃Esc)"))
        }
    }

    private func activeFilterPill(icon: String, title: String, isAccent: Bool, onRemove: @escaping () -> Void) -> some View {
        Button(action: onRemove) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .opacity(0.85)
            }
            .foregroundStyle(isAccent ? Color.white : Color.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 3.5)
            .background(
                Capsule()
                    .fill(isAccent ? Color.accentColor : Color.primary.opacity(0.10))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func narrowingTags(for library: LibraryProjection) -> [String] {
        guard !store.filterUntaggedOnly else { return [] }
        let counts = store.searchTokens.isEmpty ? library.tagCounts : library.narrowedTagCounts
        let activeTags = store.activeFilterTags
        let outline = TagCatalog.flattenedOutline(in: store.tagNodes)

        var candidates: [(isChildOfActive: Bool, count: Int, order: Int, name: String)] = []
        for (idx, row) in outline.enumerated() {
            let name = row.node.name
            if store.hasSearchTag(name) { continue }
            if activeTags.contains(where: { TagCatalog.isDescendant($0, of: name, in: store.tagNodes) }) {
                continue
            }
            let family = store.expandedTagFamily(for: name)
            let matchedCount = family.reduce(0) { $0 + counts[$1, default: 0] }
            guard matchedCount > 0 else { continue }
            let isChildOfActive = row.node.parent.map { store.hasSearchTag($0) } ?? false
            candidates.append((isChildOfActive, matchedCount, idx, name))
        }

        return candidates
            .sorted { lhs, rhs in
                if lhs.isChildOfActive != rhs.isChildOfActive { return lhs.isChildOfActive }
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.order < rhs.order
            }
            .prefix(8)
            .map(\.name)
    }

    // MARK: - Window Toolbar

    @ToolbarContentBuilder
    private func toolbarContent(showsDetails: Bool, library: LibraryProjection) -> some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                store.tagPickerItemID = nil
                store.isQuickFindPresented.toggle()
            } label: {
                Label(lang.tr("快速查找", "Quick Find"), systemImage: "magnifyingglass")
            }
            .help(lang.tr("快速查找与标签筛选 (⌘F)", "Quick Find & Tag Search (⌘F)"))
        }

        ToolbarItem(placement: .primaryAction) {
            tagFilterMenu(library: library)
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                store.selectedItemID = nil
            } label: {
                Label(lang.tr("收起详情栏", "Hide Details"), systemImage: "sidebar.right")
            }
            .disabled(!showsDetails)
            .help(lang.tr("收起右侧详情面板", "Hide right details panel"))
        }
    }

    private func tagFilterMenu(library: LibraryProjection) -> some View {
        let sections = TagCatalog.groupedOutline(categories: store.tagCategories, nodes: store.tagNodes)
        let untaggedCount = library.untaggedCount > 0 ? library.untaggedCount : store.totalUntaggedCount

        return Menu {
            if store.hasActiveTagFilter {
                Button(lang.tr("清除标签筛选", "Clear Tag Filters")) {
                    store.searchTokens.removeAll()
                    store.filterUntaggedOnly = false
                }
                Divider()
            }

            if untaggedCount > 0 || store.filterUntaggedOnly {
                let noTagLabel = untaggedCount > 0
                    ? "\(lang.tr("无标签", "No Tag")) (\(untaggedCount))"
                    : lang.tr("无标签", "No Tag")
                Button {
                    store.toggleUntaggedFilter()
                } label: {
                    if store.filterUntaggedOnly {
                        Label(noTagLabel, systemImage: "checkmark")
                    } else {
                        Text(noTagLabel)
                    }
                }
                Divider()
            }

            if sections.isEmpty {
                Text(lang.tr("暂无标签", "No Tags"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(sections) { section in
                    let sectionTitle = section.category.map { MediaCategory.localizedTag($0, in: lang) }
                        ?? lang.tr("未分类", "Uncategorized")
                    Section(sectionTitle) {
                        ForEach(section.rows) { row in
                            let count = store.usageCount(
                                forTag: row.node.name,
                                in: store.selectedDestination,
                                includeDescendants: true
                            )
                            let indent = String(repeating: "  ", count: row.depth)
                            let localized = MediaCategory.localizedTag(row.node.name, in: lang)
                            let title = count > 0 ? "\(indent)\(localized) (\(count))" : "\(indent)\(localized)"
                            Button {
                                store.toggleSearchTag(row.node.name)
                            } label: {
                                if store.hasSearchTag(row.node.name) {
                                    Label(title, systemImage: "checkmark")
                                } else {
                                    Text(title)
                                }
                            }
                        }
                    }
                }
            }

            Divider()

            Button {
                TagWindowController.shared.show(store: store)
            } label: {
                Label(lang.tr("管理标签… (⌃⌘T)", "Manage Tags… (⌃⌘T)"), systemImage: "slider.horizontal.3")
            }
        } label: {
            Label(
                lang.tr("按标签筛选", "Filter by Tag"),
                systemImage: store.hasActiveTagFilter ? "tag.fill" : "tag"
            )
        }
        .help(lang.tr("按标签筛选", "Filter by Tag"))
    }

    private var defaultCategoryForNewItem: MediaCategory {
        if case .category(let cat) = store.selectedDestination {
            return cat
        }
        return .game
    }

    private var defaultStatusForNewItem: TrackingStatus {
        if case .single(let st) = store.statusFilter {
            return st
        }
        return .active
    }
}

private struct LibraryToastView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let toast = store.toastMessage {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(toast)
                        .font(.system(size: 12.5, weight: .medium))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
                .overlay { Capsule().strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.8) }
                .shadow(color: .black.opacity(0.22), radius: 10, x: 0, y: 4)
                .padding(.bottom, 14)
                .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: store.toastMessage != nil)
    }
}
