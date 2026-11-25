import AppKit
import SwiftUI

struct QuickFindOverlay: View {
    let store: LibraryStore
    let library: LibraryProjection
    let language: AppLanguage
    let onDismiss: () -> Void

    @State private var query: String = ""
    @State private var highlightedIndex: Int = 0
    @State private var hoveredID: String? = nil
    @State private var preparedItems: (request: LibraryQuery.QuickFindRequest, items: [MediaItem])?

    private enum EntryKind {
        case untagged
        case tag(TagOutlineRow)
        case manageTags
        case destination(SidebarDestination)
        case searchAllItems(String)
        case item(MediaItem)
    }

    private struct Entry: Identifiable {
        let id: String
        let kind: EntryKind
    }

    private struct SectionGroup: Identifiable {
        let id: String
        let title: String
        let entries: [Entry]
    }

    private static let untaggedKeywords = ["无标签", "未标记", "no tag", "untagged"]

    private var trimmedQuery: String { query.trimmed }

    private func sections(items: [MediaItem]) -> [SectionGroup] {
        var groups: [SectionGroup] = []

        if trimmedQuery.isEmpty {
            var tagEntries: [Entry] = []
            if library.untaggedCount > 0 || store.totalUntaggedCount > 0 || store.filterUntaggedOnly {
                tagEntries.append(Entry(id: "untagged", kind: .untagged))
            }
            for row in TagCatalog.flattenedOutline(in: store.tagNodes) {
                tagEntries.append(Entry(id: "tag:\(row.id)", kind: .tag(row)))
            }
            if !tagEntries.isEmpty {
                groups.append(SectionGroup(id: "tags", title: language.tr("按标签筛选", "Filter by Tag"), entries: tagEntries))
            }
            groups.append(SectionGroup(
                id: "management",
                title: language.tr("标签管理", "Management"),
                entries: [Entry(id: "manage-tags", kind: .manageTags)]
            ))
            return groups
        }

        var matchedTagEntries: [Entry] = []
        if Self.untaggedKeywords.contains(where: {
            $0.localizedCaseInsensitiveContains(trimmedQuery) || trimmedQuery.localizedCaseInsensitiveContains($0)
        }) {
            matchedTagEntries.append(Entry(id: "untagged", kind: .untagged))
        }
        for row in TagCatalog.searchRows(matching: trimmedQuery, in: store.tagNodes) {
            matchedTagEntries.append(Entry(id: "tag:\(row.id)", kind: .tag(row)))
        }
        if !matchedTagEntries.isEmpty {
            groups.append(SectionGroup(id: "tags", title: language.tr("标签", "Tags"), entries: matchedTagEntries))
        }

        let matchedDestinations = SidebarDestination.allDestinations.filter { dest in
            dest.title(in: .zh).localizedCaseInsensitiveContains(trimmedQuery)
                || dest.title(in: .en).localizedCaseInsensitiveContains(trimmedQuery)
        }
        if !matchedDestinations.isEmpty {
            groups.append(SectionGroup(
                id: "lists",
                title: language.tr("分类列表", "Lists"),
                entries: matchedDestinations.map { Entry(id: "dest:\($0.stableID)", kind: .destination($0)) }
            ))
        }

        var itemEntries: [Entry] = [Entry(id: "search-all", kind: .searchAllItems(trimmedQuery))]
        for item in items {
            itemEntries.append(Entry(id: "item:\(item.id.uuidString)", kind: .item(item)))
        }
        groups.append(SectionGroup(id: "items", title: language.tr("作品", "Items"), entries: itemEntries))
        return groups
    }

    var body: some View {
        let request = store.shouldProjectInBackground && !trimmedQuery.isEmpty
            ? store.quickFindRequest(matching: trimmedQuery) : nil
        let items = if let request {
            preparedItems?.request == request ? (preparedItems?.items ?? []) : []
        } else {
            store.topQuickFindItems(matching: trimmedQuery)
        }
        let grouped = sections(items: items)
        let flatEntries = grouped.flatMap(\.entries)
        let safeIndex = flatEntries.isEmpty ? 0 : min(max(highlightedIndex, 0), flatEntries.count - 1)
        let indexByID = Dictionary(uniqueKeysWithValues: flatEntries.enumerated().map { ($0.element.id, $0.offset) })

        ModalOverlayContainer(width: 480, topPadding: 56, cornerRadius: 14, backdropOpacity: 0.22, showsBackdrop: false, onDismiss: onDismiss) {
            VStack(spacing: 0) {
                ShelfSearchBar(
                    placeholder: language.tr("快速切换分类、查找作品或搜索标签…", "Quickly switch lists, find items, or search tags…"),
                    text: $query,
                    autoFocus: true,
                    font: .systemFont(ofSize: 15),
                    iconSize: 15,
                    spacing: 10,
                    fieldHeight: 24,
                    horizontalPadding: 14,
                    verticalPadding: 12,
                    showsChrome: false,
                    onMoveUp: {
                        guard !flatEntries.isEmpty else { return }
                        highlightedIndex = (safeIndex - 1 + flatEntries.count) % flatEntries.count
                    },
                    onMoveDown: {
                        guard !flatEntries.isEmpty else { return }
                        highlightedIndex = (safeIndex + 1) % flatEntries.count
                    },
                    onSubmit: { flags in
                        guard flatEntries.indices.contains(safeIndex) else {
                            onDismiss()
                            return
                        }
                        activateEntry(flatEntries[safeIndex], modifiers: flags)
                    },
                    onEscape: onDismiss,
                    trailingHint: "Esc",
                    alwaysShowTrailingHint: true
                )

                ShelfHairline()

                if flatEntries.isEmpty {
                    Text(language.tr("无匹配结果", "No Matching Results"))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 34)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(grouped) { section in
                                    Section {
                                        ForEach(section.entries) { entry in
                                            let rowIdx = indexByID[entry.id] ?? -1
                                            entryRow(entry, isHighlighted: rowIdx == safeIndex)
                                                .id(entry.id)
                                        }
                                    } header: {
                                        Text(section.title)
                                            .font(.system(size: 10.5, weight: .semibold))
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 8)
                                            .padding(.top, section.id == grouped.first?.id ? 0 : 8)
                                            .padding(.bottom, 2)
                                    }
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 10)
                        }
                        .frame(maxHeight: 360)
                        .onChange(of: query) { _, _ in
                            highlightedIndex = 0
                        }
                        .onChange(of: flatEntries.count) { _, newCount in
                            if highlightedIndex >= newCount {
                                highlightedIndex = max(0, newCount - 1)
                            }
                        }
                        .onChange(of: highlightedIndex) { _, newIdx in
                            guard flatEntries.indices.contains(newIdx) else { return }
                            proxy.scrollTo(flatEntries[newIdx].id)
                        }
                    }
                }

                ShelfHairline()

                HStack(spacing: 12) {
                    quickFindHint("↑↓", language.tr("选择", "Select"))
                    quickFindHint("↵", language.tr("打开", "Open"))
                    quickFindHint("⌘↵", language.tr("多选标签", "Multi-tag"))
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7.5)
            }
        }
        .task(id: request) {
            guard let request else {
                preparedItems = nil
                return
            }
            guard let items = await store.backgroundQuickFind(for: request), !Task.isCancelled else { return }
            preparedItems = (request, items)
        }
    }

    private func quickFindHint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary.opacity(0.85))
        }
    }

    @ViewBuilder
    private func entryRow(_ entry: Entry, isHighlighted: Bool) -> some View {
        let isHovered = hoveredID == entry.id
        Button {
            let flags = (NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags)
                .intersection(.deviceIndependentFlagsMask)
            activateEntry(entry, modifiers: flags)
        } label: {
            rowContent(for: entry.kind)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(
                            isHighlighted
                                ? Color.accentColor.opacity(0.16)
                                : (isHovered ? Color.primary.opacity(0.06) : Color.clear)
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.10), value: isHighlighted)
        .animation(.easeOut(duration: 0.10), value: isHovered)
        .onHover { hovering in
            hoveredID = hovering ? entry.id : (hoveredID == entry.id ? nil : hoveredID)
        }
    }

    @ViewBuilder
    private func rowContent(for kind: EntryKind) -> some View {
        switch kind {
        case .untagged:
            let count = library.untaggedCount > 0 ? library.untaggedCount : store.totalUntaggedCount
            HStack(spacing: 8) {
                Image(systemName: "tag.slash")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(store.filterUntaggedOnly ? Color.accentColor : Color.secondary)
                    .frame(width: 16)

                Text(language.tr("无标签", "No Tag"))
                    .font(.system(size: 13, weight: store.filterUntaggedOnly ? .semibold : .regular))
                    .foregroundStyle(.primary)

                Spacer()

                if store.filterUntaggedOnly {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                }

                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

        case .tag(let row):
            let active = store.hasSearchTag(row.node.name)
            let destCount = store.usageCount(
                forTag: row.node.name,
                in: store.selectedDestination,
                includeDescendants: true
            )
            let count = destCount > 0
                ? destCount
                : store.usageCount(forTag: row.node.name, in: .all, includeDescendants: true)
            HStack(spacing: 8) {
                if trimmedQuery.isEmpty && row.depth > 0 {
                    Spacer().frame(width: CGFloat(row.depth) * 14)
                }

                Image(systemName: row.hasChildren ? "tag.fill" : "tag")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(active ? Color.accentColor : Color.secondary)
                    .frame(width: 16)

                Text(MediaCategory.localizedTag(row.node.name, in: language))
                    .font(.system(size: 13, weight: active ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                let breadcrumbParts = (row.category.map { [$0] } ?? []) + row.ancestors
                if !breadcrumbParts.isEmpty {
                    Text(TagCatalog.formattedBreadcrumb(ancestors: breadcrumbParts, language: language))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if active {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                }

                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

        case .manageTags:
            HStack(spacing: 8) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 16)

                Text(language.tr("管理标签…", "Manage Tags…"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)

                Spacer()

                Text("⌃⌘T")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

        case .destination(let dest):
            HStack(spacing: 8) {
                Image(systemName: dest.systemImage)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(dest.tintColor)
                    .frame(width: 16)

                Text(dest.title(in: language))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)

                Spacer()

                let count = store.count(for: dest)
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

        case .searchAllItems(let q):
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 16)

                Text(language.tr("搜索包含「\(q)」的全部作品", "Search all items for “\(q)”"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)

                Spacer()
            }

        case .item(let item):
            HStack(spacing: 8) {
                Image(systemName: item.category.systemImage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(item.category.accentColor)
                    .frame(width: 16)

                Text(item.displayTitle(in: language))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if !item.tags.isEmpty {
                    Text(
                        item.tags.prefix(3)
                            .map { MediaCategory.localizedTag($0, in: language) }
                            .joined(separator: " · ")
                    )
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text(item.category.statusLabel(for: item.status, in: language))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06), in: Capsule())
            }
        }
    }

    private func activateEntry(_ entry: Entry, modifiers: NSEvent.ModifierFlags) {
        switch entry.kind {
        case .untagged:
            store.selectUntaggedFilter(switchToAllIfEmptyInCurrentDestination: true)
            onDismiss()

        case .tag(let row):
            if modifiers.contains(.command) {
                store.toggleSearchTag(row.node.name)
            } else {
                store.selectSingleTagFilter(row.node.name, switchToAllIfEmptyInCurrentDestination: true)
                onDismiss()
            }

        case .manageTags:
            onDismiss()
            TagWindowController.shared.show(store: store)

        case .destination(let dest):
            store.selectDestination(dest)
            onDismiss()

        case .searchAllItems(let q):
            store.searchAllItems(q)
            onDismiss()

        case .item(let item):
            store.revealItem(item)
            onDismiss()
        }
    }
}
