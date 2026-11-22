import SwiftUI

struct MainWindowView: View {
    @Environment(LibraryStore.self) private var store
    @Binding var showAddSheet: Bool
    @AppStorage(PosterScaleConfig.storageKey) private var posterScale: Double = PosterScaleConfig.defaultScale
    @AppStorage(TimelineZoomConfig.storageKey) private var timelineZoom: Double = TimelineZoomConfig.defaultZoom
    @AppStorage("shelf.collapsedShelves") private var collapsedShelvesRaw: String = ""

    @State private var editingItem: MediaItem? = nil
    @State private var coverReplacingItem: MediaItem? = nil
    @State private var quickAddPresetStatus: TrackingStatus? = nil
    @State private var preparedLibrary: (LibraryQuery.Request, LibraryProjection)?
    @State private var draggedPosterScale: Double?
    @State private var draggedTimelineZoom: Double?

    private var lang: AppLanguage { store.language }

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
        let isTimeline = store.selectedDestination.isTimeline
        let visibleCount: Int = {
            guard isTimeline else { return library.count }
            return library.sections
                .flatMap(\.items)
                .filter { store.timelineCategories.contains($0.category) && ($0.startedAt != nil || $0.finishedAt != nil) }
                .count
        }()

        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 195, ideal: 215, max: 260)
        } detail: {
            GeometryReader { workspace in
                VStack(alignment: .leading, spacing: 0) {
                    if !isTimeline {
                        ShelfTopControlBar(counts: library.statusCounts) {
                            quickAddPresetStatus = nil
                            showAddSheet = true
                        }
                        Divider()
                    }

                    libraryCanvas(
                        library,
                        options: options,
                        waiting: backgroundRequest != nil && prepared == nil,
                        posterWidthBasis: workspace.size.width
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .bottom) { LibraryToastView() }

                    Divider()
                    ShelfBottomStatusBar(
                        countText: statusBarCountText(visibleCount, isTimeline: isTimeline),
                        isTimeline: isTimeline,
                        language: lang,
                        posterScale: $posterScale,
                        draggedPosterScale: $draggedPosterScale,
                        timelineZoom: $timelineZoom,
                        draggedTimelineZoom: $draggedTimelineZoom
                    )
                }
                .modifier(DetailDrawerLayout(
                    workspaceWidth: workspace.size.width,
                    initialPosterID: library.sections.first?.items.first?.id,
                    onReplaceCover: { coverReplacingItem = $0 }
                ))
                .overlay {
                    if store.isQuickFindPresented {
                        QuickFindOverlay(store: store, library: library, language: lang) {
                            store.isQuickFindPresented = false
                        }
                        .transition(.opacity)
                    } else if let pickerItemID = store.tagPickerItemID,
                              store.item(withID: pickerItemID) != nil {
                        TagPickerOverlay(store: store, itemID: pickerItemID, language: lang) {
                            store.tagPickerItemID = nil
                        }
                        .transition(.opacity)
                    }
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationTitle(store.selectedDestination.title(in: lang))
            .navigationSubtitle(itemCountText(visibleCount, compact: true))
            .toolbar {
                toolbarContent(showsDetails: showsDetails, untaggedCountInView: library.untaggedCount)
            }
        }
        .sheet(isPresented: $showAddSheet, onDismiss: { quickAddPresetStatus = nil }) {
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
        }
        return count == 1 ? "1 item" : "\(count) items"
    }

    private func statusBarCountText(_ count: Int, isTimeline: Bool) -> String {
        if isTimeline {
            if lang == .zh {
                return "时间线已排期 \(count) 项"
            }
            return count == 1 ? "1 item on timeline" : "\(count) items on timeline"
        }
        return itemCountText(count, compact: false)
    }

    private func libraryCanvas(
        _ library: LibraryProjection,
        options: LibraryQuery.Options,
        waiting: Bool,
        posterWidthBasis: CGFloat
    ) -> some View {
        VStack(spacing: 0) {
            if store.hasActiveFilter {
                ActiveFilterBar(library: library)
                Divider()
            }

            if store.isLoading || waiting {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.loadFailed {
                Text(lang.tr("无法读取作品库文件", "Could not read the library file"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if options.destination.isTimeline {
                TimelineView(
                    posters: library.sections.flatMap(\.items),
                    selectedItemID: store.selectedItemID,
                    zoom: $timelineZoom,
                    effectiveZoom: draggedTimelineZoom ?? timelineZoom,
                    language: options.language,
                    actions: timelineActions
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if library.count == 0 {
                Spacer(minLength: 0)
                LibraryEmptyStateView {
                    quickAddPresetStatus = nil
                    showAddSheet = true
                }
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
                    actions: gridActions
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var gridActions: PosterGridActions {
        PosterGridActions(
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
                store.isQuickFindPresented = false
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
    }

    private var timelineActions: TimelineActions {
        TimelineActions(
            onSelectItem: { id in
                store.selectedItemID = store.selectedItemID == id ? nil : id
            },
            onEnsureSelectItem: { id in
                if store.selectedItemID != id { store.selectedItemID = id }
            },
            onDeselectAll: {
                if store.selectedItemID != nil {
                    store.selectedItemID = nil
                }
            },
            onDoubleClickEdit: { id in
                editingItem = store.item(withID: id)
            },
            onRequestEditTags: { id in
                store.isQuickFindPresented = false
                store.selectedItemID = id
                store.tagPickerItemID = id
            },
            onRequestReplaceCover: { id in
                coverReplacingItem = store.item(withID: id)
            },
            onChangeStatus: { id, status in
                store.updateStatus(for: id, to: status)
            },
            onChangeRating: { id, stars in
                store.updateRating(for: id, rating: stars)
            },
            onClearDates: { id in
                store.updateTimelineDates(for: id, startedAt: nil, finishedAt: nil)
                store.showToast(lang.tr("已清除时间线日期", "Cleared timeline dates"))
            },
            onDeleteItem: { id in
                store.deleteItem(id: id)
            },
            onAddItem: {
                quickAddPresetStatus = nil
                showAddSheet = true
            }
        )
    }

    @ToolbarContentBuilder
    private func toolbarContent(showsDetails: Bool, untaggedCountInView: Int) -> some ToolbarContent {
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
            TagFilterToolbarMenu(untaggedCountInView: untaggedCountInView)
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
