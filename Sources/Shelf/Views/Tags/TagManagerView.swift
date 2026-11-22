import AppKit
import SwiftUI

struct TagManagerView: View {
    @Environment(LibraryStore.self) private var store

    let onFilterApplied: () -> Void
    let onUpdateTitle: (String) -> Void
    let registerEscapeHandler: ((@escaping () -> Bool) -> Void)

    private enum InlineMode: Equatable {
        case none
        case creatingCategory
        case creatingTag(category: String?, parent: String?)
        case renamingTag(String)
        case renamingCategory(String)
        case confirmingDeleteTag(String)
        case confirmingDeleteCategory(String)
    }

    @State private var filterText: String = ""
    @State private var collapsedIDs: Set<String> = []
    @State private var collapsedCategoryIDs: Set<String> = []
    @State private var selectedTagName: String? = nil
    @State private var hoveredTagID: String? = nil
    @State private var hoveredCategoryID: String? = nil

    @State private var inlineMode: InlineMode = .none
    @State private var draftText: String = ""

    @State private var dropTargetRowID: String? = nil
    @State private var dropTargetCategoryID: String? = nil
    @State private var isRootDropTargeted: Bool = false

    private var lang: AppLanguage { store.language }
    private var trimmedFilter: String { filterText.trimmed }

    private var groupedSections: [TagCategorySection] {
        TagCatalog.groupedOutline(
            categories: store.tagCategories,
            nodes: store.tagNodes,
            collapsedTagIDs: collapsedIDs,
            includeEmptyCategories: true
        )
    }

    private var visibleRows: [TagOutlineRow] {
        if trimmedFilter.isEmpty {
            return groupedSections.flatMap(\.rows)
        }
        return TagCatalog.searchRows(matching: trimmedFilter, in: store.tagNodes)
    }

    private var selectedExistingTag: String? {
        guard let selectedTagName else { return nil }
        return store.tagExists(selectedTagName) ? selectedTagName : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            headerToolbar
            Divider()

            confirmationBannerSection

            if trimmedFilter.isEmpty {
                groupedListContent
            } else {
                filteredListContent
            }

            Divider()
            footerBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            onUpdateTitle(lang.tr("管理标签", "Manage Tags"))
            registerEscapeHandler {
                if inlineMode != .none {
                    cancelInlineMode()
                    return false
                }
                if !filterText.isEmpty {
                    filterText = ""
                    return false
                }
                return true
            }
        }
        .onChange(of: store.language) { _, newLang in
            onUpdateTitle(newLang.tr("管理标签", "Manage Tags"))
        }
    }

    // MARK: - Confirmation Banner

    @ViewBuilder
    private var confirmationBannerSection: some View {
        switch inlineMode {
        case .confirmingDeleteTag(let target):
            let shown = MediaCategory.localizedTag(target, in: lang)
            let nestedCount = store.nestedChildCount(for: target)
            let itemCount = store.usageCount(forTag: target, includeDescendants: true)
            let message: String = nestedCount > 0
                ? lang.tr(
                    "确定要删除「\(shown)」吗？其下嵌套的 \(nestedCount) 个子标签也将被删除，并从 \(itemCount) 部作品中移除。",
                    "Delete “\(shown)”? The \(nestedCount) nested subtag(s) will also be deleted and removed from \(itemCount) item(s)."
                )
                : lang.tr(
                    "确定要删除「\(shown)」吗？将从 \(itemCount) 部作品中移除。",
                    "Delete “\(shown)”? It will be removed from \(itemCount) item(s)."
                )
            TagDeleteConfirmationBanner(
                message: message,
                language: lang,
                onConfirm: {
                    store.deleteTag(target)
                    cancelInlineMode()
                    if let selectedTagName, MediaCategory.tagsMatch(selectedTagName, target) {
                        self.selectedTagName = nil
                    }
                },
                onCancel: cancelInlineMode
            )
            Divider()

        case .confirmingDeleteCategory(let targetCategory):
            let shown = MediaCategory.localizedTag(targetCategory, in: lang)
            let tagCount = store.tagCount(inCategory: targetCategory)
            let message = lang.tr(
                "确定要删除分类「\(shown)」吗？其中的 \(tagCount) 个标签将移至「未分类」（不会从作品中移除）。",
                "Delete category “\(shown)”? Its \(tagCount) tag(s) will move to Uncategorized (items keep their tags)."
            )
            TagDeleteConfirmationBanner(
                message: message,
                language: lang,
                onConfirm: {
                    store.deleteTagCategory(targetCategory)
                    cancelInlineMode()
                },
                onCancel: cancelInlineMode
            )
            Divider()

        default:
            EmptyView()
        }
    }

    // MARK: - Header Toolbar

    private var headerToolbar: some View {
        HStack(spacing: 8) {
            ShelfSearchBar(
                placeholder: lang.tr("筛选标签…", "Filter tags…"),
                text: $filterText,
                font: .systemFont(ofSize: 12.5),
                iconSize: 11.5,
                horizontalPadding: 8,
                verticalPadding: 5,
                cornerRadius: 7,
                fillOpacity: 0.055,
                borderOpacity: 0.11,
                onEscape: { filterText = "" },
                interceptEscapeWhenEmpty: false
            )

            Button {
                let selectedCat = selectedExistingTag.flatMap { name in
                    store.tagNodes.first(where: { MediaCategory.tagsMatch($0.name, name) })?.category
                }
                beginCreatingTag(inCategory: selectedCat, under: nil)
            } label: {
                Label(lang.tr("新建标签", "New Tag"), systemImage: "plus")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(ShelfButtonStyle(variant: .primary, horizontalPadding: 10, verticalPadding: 5, cornerRadius: 7))

            Button(action: beginCreatingCategory) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .buttonStyle(ShelfButtonStyle(variant: .secondary, horizontalPadding: 8, verticalPadding: 5, cornerRadius: 7))
            .help(lang.tr("新建标签分类", "New Tag Category"))

            Button {
                beginCreatingTag(inCategory: nil, under: selectedExistingTag)
            } label: {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .buttonStyle(ShelfButtonStyle(variant: .secondary, horizontalPadding: 8, verticalPadding: 5, cornerRadius: 7))
            .disabled(selectedExistingTag == nil)
            .help(lang.tr("在选中标签下新建子标签", "New subtag under selection"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Main Lists

    @ViewBuilder
    private var groupedListContent: some View {
        let isCreatingTopLevelUncategorized: Bool = {
            if case .creatingTag(category: nil, parent: nil) = inlineMode { return true }
            return false
        }()

        if groupedSections.isEmpty && inlineMode == .none {
            emptyState
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    if case .creatingCategory = inlineMode {
                        TagInlineCreateRow(
                            icon: "folder.fill",
                            placeholder: lang.tr("输入新分类名称（如：风格、平台），回车创建…", "New category name, press Return…"),
                            draft: $draftText,
                            language: lang,
                            onCommit: commitNewCategory,
                            onCancel: cancelInlineMode
                        )
                    }

                    if isCreatingTopLevelUncategorized {
                        inlineCreateTagRow(depth: 0, category: nil, parent: nil)
                    }

                    ForEach(groupedSections) { section in
                        categoryHeader(section)

                        let isCreatingHere: Bool = {
                            if case .creatingTag(let targetCat, nil) = inlineMode,
                               let cat = section.category, let targetCat {
                                return MediaCategory.tagsMatch(cat, targetCat)
                            }
                            return false
                        }()

                        if isCreatingHere {
                            inlineCreateTagRow(depth: 0, category: section.category, parent: nil)
                        }

                        if !collapsedCategoryIDs.contains(section.id) {
                            if section.rows.isEmpty && !isCreatingHere {
                                Text(lang.tr("拖拽标签至此，或点击 + 新建", "Drag tags here or click + to add"))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                                    .padding(.leading, 26)
                                    .padding(.vertical, 3)
                            } else {
                                ForEach(section.rows) { row in
                                    tagRow(row)
                                    if case .creatingTag(_, let parentName?) = inlineMode,
                                       MediaCategory.tagsMatch(parentName, row.node.name) {
                                        inlineCreateTagRow(depth: row.depth + 1, category: row.category, parent: row.node.name)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(10)
            }
        }
    }

    @ViewBuilder
    private var filteredListContent: some View {
        if visibleRows.isEmpty && inlineMode == .none {
            emptyState
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(visibleRows) { row in
                        tagRow(row)
                        if case .creatingTag(_, let parentName?) = inlineMode,
                           MediaCategory.tagsMatch(parentName, row.node.name) {
                            inlineCreateTagRow(depth: row.depth + 1, category: row.category, parent: row.node.name)
                        }
                    }
                }
                .padding(10)
            }
        }
    }

    private func inlineCreateTagRow(depth: Int, category: String?, parent: String?) -> some View {
        TagInlineCreateRow(
            icon: "tag.fill",
            placeholder: parent == nil
                ? lang.tr("输入新标签名称，回车创建…", "New tag name, press Return…")
                : lang.tr("输入子标签名称，回车创建…", "Subtag name, press Return…"),
            draft: $draftText,
            language: lang,
            leadingIndent: CGFloat(depth) * 18 + 22,
            onCommit: { commitNewTag(category: category, parent: parent) },
            onCancel: cancelInlineMode
        )
    }

    // MARK: - Category Header & Tag Rows

    private func categoryHeader(_ section: TagCategorySection) -> some View {
        let isCollapsed = collapsedCategoryIDs.contains(section.id)
        let isHovered = hoveredCategoryID == section.id
        let isDropTarget = dropTargetCategoryID == section.id
        let isRenaming: Bool = {
            if case .renamingCategory(let target) = inlineMode, let cat = section.category {
                return MediaCategory.tagsMatch(target, cat)
            }
            return false
        }()
        let displayName = section.category.map { MediaCategory.localizedTag($0, in: lang) }
            ?? lang.tr("未分类", "Uncategorized")
        let count = store.tagCount(inCategory: section.category)

        return HStack(spacing: 6) {
            Button {
                if isCollapsed {
                    collapsedCategoryIDs.remove(section.id)
                } else {
                    collapsedCategoryIDs.insert(section.id)
                }
            } label: {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Image(systemName: section.category == nil ? "tray" : "folder.fill")
                .font(.system(size: 11))
                .foregroundStyle(isDropTarget ? Color.accentColor : Color.secondary)

            if isRenaming, let cat = section.category {
                SearchCommandTextField(
                    placeholder: lang.tr("分类名称", "Category name"),
                    text: $draftText,
                    autoFocus: true,
                    font: .systemFont(ofSize: 12, weight: .semibold),
                    onSubmit: { _ in commitCategoryRename(from: cat) },
                    onEscape: cancelInlineMode
                )
                .frame(height: 18)
            } else {
                Text(displayName)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text("\(count)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 6)

            if isHovered && !isRenaming {
                HStack(spacing: 3) {
                    rowActionButton("plus", help: lang.tr("在此分类下新建标签", "New tag in this category")) {
                        beginCreatingTag(inCategory: section.category, under: nil)
                    }
                    if let cat = section.category {
                        rowActionButton("pencil", help: lang.tr("重命名分类", "Rename category")) {
                            startCategoryRename(cat)
                        }
                        rowActionButton("trash", help: lang.tr("删除分类", "Delete category")) {
                            requestDeleteCategory(cat)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .padding(.top, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isDropTarget ? Color.accentColor.opacity(0.14) : (isHovered ? Color.primary.opacity(0.04) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(isDropTarget ? Color.accentColor : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveredCategoryID = hovering ? section.id : (hoveredCategoryID == section.id ? nil : hoveredCategoryID)
        }
        .onTapGesture(count: 2) {
            if let cat = section.category { startCategoryRename(cat) }
        }
        .dropDestination(for: String.self) { droppedItems, _ in
            guard let dropped = droppedItems.first, store.tagExists(dropped) else { return false }
            collapsedCategoryIDs.remove(section.id)
            store.setTagCategory(dropped, category: section.category)
            return true
        } isTargeted: { targeted in
            dropTargetCategoryID = targeted ? section.id : (dropTargetCategoryID == section.id ? nil : dropTargetCategoryID)
        }
        .contextMenu {
            Button {
                beginCreatingTag(inCategory: section.category, under: nil)
            } label: {
                Label(lang.tr("在此分类下新建标签…", "New Tag in Category…"), systemImage: "plus")
            }

            if let cat = section.category {
                Button {
                    startCategoryRename(cat)
                } label: {
                    Label(lang.tr("重命名分类…", "Rename Category…"), systemImage: "pencil")
                }

                Divider()

                Button(role: .destructive) {
                    requestDeleteCategory(cat)
                } label: {
                    Label(lang.tr("删除分类…", "Delete Category…"), systemImage: "trash")
                }
            }
        }
    }

    private func tagRow(_ row: TagOutlineRow) -> some View {
        let isSelected = selectedTagName.map { MediaCategory.tagsMatch($0, row.node.name) } ?? false
        let isHovered = hoveredTagID == row.id
        let isDropTarget = dropTargetRowID == row.id
        let isCollapsed = collapsedIDs.contains(row.id)
        let isRenaming: Bool = {
            if case .renamingTag(let target) = inlineMode {
                return MediaCategory.tagsMatch(target, row.node.name)
            }
            return false
        }()
        let count = store.usageCount(forTag: row.node.name, includeDescendants: true)

        return HStack(spacing: 6) {
            if trimmedFilter.isEmpty && row.depth > 0 {
                Spacer().frame(width: CGFloat(row.depth) * 18)
            }

            if trimmedFilter.isEmpty && row.hasChildren {
                Button {
                    toggleCollapse(row.id)
                } label: {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Spacer().frame(width: 16)
            }

            Image(systemName: row.hasChildren ? "tag.fill" : "tag")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .frame(width: 15)

            if isRenaming {
                SearchCommandTextField(
                    placeholder: lang.tr("标签名称", "Tag name"),
                    text: $draftText,
                    autoFocus: true,
                    font: .systemFont(ofSize: 12.5),
                    onSubmit: { _ in commitRename(from: row.node.name) },
                    onEscape: cancelInlineMode
                )
                .frame(height: 19)
            } else {
                Text(MediaCategory.localizedTag(row.node.name, in: lang))
                    .font(.system(size: 12.5, weight: row.hasChildren ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                let breadcrumb = row.fullBreadcrumb(in: lang)
                if !trimmedFilter.isEmpty && !breadcrumb.isEmpty {
                    Text(breadcrumb)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if isHovered && !isRenaming {
                HStack(spacing: 3) {
                    rowActionButton("plus", help: lang.tr("新建子标签", "New Subtag")) {
                        beginCreatingTag(inCategory: row.category, under: row.node.name)
                    }
                    rowActionButton("line.3.horizontal.decrease.circle", help: lang.tr("在作品库中筛选", "Filter in Shelf")) {
                        store.selectSingleTagFilter(row.node.name, switchToAllIfEmptyInCurrentDestination: true)
                        onFilterApplied()
                    }
                    rowActionButton("pencil", help: lang.tr("重命名", "Rename")) {
                        startRename(row.node.name)
                    }
                    rowActionButton("trash", help: lang.tr("删除", "Delete")) {
                        requestDelete(row.node.name)
                    }
                }
            }

            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Color.primary.opacity(0.06), in: Capsule())
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5.5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(
                    isDropTarget
                        ? Color.accentColor.opacity(0.22)
                        : (isSelected
                            ? Color.accentColor.opacity(0.14)
                            : (isHovered ? Color.primary.opacity(0.055) : Color.clear))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(isDropTarget ? Color.accentColor : Color.clear, lineWidth: 1.2)
        )
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onHover { hovering in
            hoveredTagID = hovering ? row.id : (hoveredTagID == row.id ? nil : hoveredTagID)
        }
        .onTapGesture(count: 2) {
            selectedTagName = row.node.name
            startRename(row.node.name)
        }
        .onTapGesture(count: 1) {
            selectedTagName = row.node.name
        }
        .draggable(row.node.name)
        .dropDestination(for: String.self) { droppedItems, _ in
            guard let dropped = droppedItems.first else { return false }
            guard TagCatalog.canSetParent(of: dropped, to: row.node.name, in: store.tagNodes) else { return false }
            collapsedIDs.remove(row.id)
            store.setTagParent(dropped, parent: row.node.name)
            return true
        } isTargeted: { targeted in
            dropTargetRowID = targeted ? row.id : (dropTargetRowID == row.id ? nil : dropTargetRowID)
        }
        .contextMenu { rowContextMenu(row) }
    }

    @ViewBuilder
    private func rowContextMenu(_ row: TagOutlineRow) -> some View {
        let shown = MediaCategory.localizedTag(row.node.name, in: lang)

        Button {
            store.selectSingleTagFilter(row.node.name, switchToAllIfEmptyInCurrentDestination: true)
            onFilterApplied()
        } label: {
            Label(lang.tr("在作品库中筛选「\(shown)」", "Filter by “\(shown)”"), systemImage: "line.3.horizontal.decrease.circle")
        }

        Button {
            beginCreatingTag(inCategory: row.category, under: row.node.name)
        } label: {
            Label(lang.tr("新建子标签…", "New Subtag…"), systemImage: "plus")
        }

        Menu {
            Button {
                store.setTagCategory(row.node.name, category: nil)
            } label: {
                if row.category == nil {
                    Label(lang.tr("未分类", "Uncategorized"), systemImage: "checkmark")
                } else {
                    Text(lang.tr("未分类", "Uncategorized"))
                }
            }

            if !store.tagCategories.isEmpty {
                Divider()
                ForEach(store.tagCategories, id: \.self) { category in
                    let isCurrent = row.category.map { MediaCategory.tagsMatch($0, category) } ?? false
                    let title = MediaCategory.localizedTag(category, in: lang)
                    Button {
                        collapsedCategoryIDs.remove(MediaCategory.tagMatchKey(category))
                        store.setTagCategory(row.node.name, category: category)
                    } label: {
                        if isCurrent {
                            Label(title, systemImage: "checkmark")
                        } else {
                            Text(title)
                        }
                    }
                }
            }
        } label: {
            Label(lang.tr("所属分类", "Category"), systemImage: "tray.full")
        }

        Menu {
            Button {
                store.setTagParent(row.node.name, parent: nil)
            } label: {
                if row.node.parent == nil {
                    Label(lang.tr("无（顶级标签）", "None (Top Level)"), systemImage: "checkmark")
                } else {
                    Text(lang.tr("无（顶级标签）", "None (Top Level)"))
                }
            }

            Divider()

            let validParents = TagCatalog.flattenedOutline(in: store.tagNodes).filter { candidate in
                TagCatalog.canSetParent(of: row.node.name, to: candidate.node.name, in: store.tagNodes)
            }
            ForEach(validParents) { candidate in
                let isCurrentParent = row.node.parent.map { MediaCategory.tagsMatch($0, candidate.node.name) } ?? false
                let indent = String(repeating: "  ", count: candidate.depth)
                let title = indent + MediaCategory.localizedTag(candidate.node.name, in: lang)
                Button {
                    collapsedIDs.remove(candidate.id)
                    store.setTagParent(row.node.name, parent: candidate.node.name)
                } label: {
                    if isCurrentParent {
                        Label(title, systemImage: "checkmark")
                    } else {
                        Text(title)
                    }
                }
            }
        } label: {
            Label(lang.tr("所属父标签", "Parent Tag"), systemImage: "folder")
        }

        // Scope top-level sibling reordering to the same category so Move Up/Down stays visually predictable.
        let siblings: [TagNode] = {
            let raw = TagCatalog.children(of: row.node.parent, in: store.tagNodes)
            guard row.node.parent == nil else { return raw }
            let rowCatKey = row.category.map(MediaCategory.tagMatchKey)
            return raw.filter { $0.category.map(MediaCategory.tagMatchKey) == rowCatKey }
        }()
        if let siblingIndex = siblings.firstIndex(where: { MediaCategory.tagsMatch($0.name, row.node.name) }) {
            if siblingIndex > 0 {
                Button {
                    store.moveTag(row.node.name, toParent: row.node.parent, before: siblings[siblingIndex - 1].name)
                } label: {
                    Label(lang.tr("上移", "Move Up"), systemImage: "arrow.up")
                }
            }
            if siblingIndex + 1 < siblings.count {
                Button {
                    let targetBefore = (siblingIndex + 2 < siblings.count) ? siblings[siblingIndex + 2].name : nil
                    store.moveTag(row.node.name, toParent: row.node.parent, before: targetBefore)
                } label: {
                    Label(lang.tr("下移", "Move Down"), systemImage: "arrow.down")
                }
            }
        }

        Divider()

        Button {
            startRename(row.node.name)
        } label: {
            Label(lang.tr("重命名…", "Rename…"), systemImage: "pencil")
        }

        Divider()

        Button(role: .destructive) {
            requestDelete(row.node.name)
        } label: {
            Label(lang.tr("删除标签…", "Delete Tag…"), systemImage: "trash")
        }
    }

    private func rowActionButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tag")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary.opacity(0.6))
            Text(trimmedFilter.isEmpty ? lang.tr("暂无标签", "No Tags Yet") : lang.tr("没有匹配的标签", "No Matching Tags"))
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footerBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.up.to.line")
                .font(.system(size: 10.5))
                .foregroundStyle(isRootDropTargeted ? Color.accentColor : Color.secondary)

            Text(
                isRootDropTargeted
                    ? lang.tr("松开以设为顶级标签", "Drop to make top-level")
                    : lang.tr("拖拽标签可嵌套分组，或拖至此栏设为顶级 · 双击重命名", "Drag to nest tags, drop here for top-level · Double-click to rename")
            )
            .font(.system(size: 11))
            .foregroundStyle(isRootDropTargeted ? Color.accentColor : Color.secondary)
            .lineLimit(1)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isRootDropTargeted ? Color.accentColor.opacity(0.14) : Color.clear)
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { droppedItems, _ in
            guard let dropped = droppedItems.first else { return false }
            guard TagCatalog.canSetParent(of: dropped, to: nil, in: store.tagNodes) else { return false }
            store.setTagParent(dropped, parent: nil)
            return true
        } isTargeted: { targeted in
            isRootDropTargeted = targeted
        }
    }

    // MARK: - State Machine Transitions

    private func cancelInlineMode() {
        inlineMode = .none
        draftText = ""
    }

    private func toggleCollapse(_ id: String) {
        if collapsedIDs.contains(id) {
            collapsedIDs.remove(id)
        } else {
            collapsedIDs.insert(id)
        }
    }

    private func beginCreatingCategory() {
        filterText = ""
        draftText = ""
        inlineMode = .creatingCategory
    }

    private func commitNewCategory() {
        let trimmed = draftText.trimmed
        if !trimmed.isEmpty {
            store.addTagCategory(trimmed)
        }
        cancelInlineMode()
    }

    private func startCategoryRename(_ category: String) {
        draftText = MediaCategory.localizedTag(category, in: lang)
        inlineMode = .renamingCategory(category)
    }

    private func commitCategoryRename(from oldCategory: String) {
        if let replacement = TagInputParser.validatedRename(from: oldCategory, draft: draftText, in: lang) {
            store.renameTagCategory(from: oldCategory, to: replacement)
        }
        cancelInlineMode()
    }

    private func requestDeleteCategory(_ category: String) {
        if store.tagCount(inCategory: category) == 0 {
            cancelInlineMode()
            store.deleteTagCategory(category)
        } else {
            draftText = ""
            inlineMode = .confirmingDeleteCategory(category)
        }
    }

    private func beginCreatingTag(inCategory category: String?, under parent: String?) {
        filterText = ""
        draftText = ""
        if let parent {
            collapsedIDs.remove(MediaCategory.tagMatchKey(parent))
        } else if let category {
            collapsedCategoryIDs.remove(MediaCategory.tagMatchKey(category))
        }
        inlineMode = .creatingTag(category: category, parent: parent)
    }

    private func commitNewTag(category: String?, parent: String?) {
        let trimmed = draftText.trimmed
        if !trimmed.isEmpty, let created = store.addTag(trimmed, category: category, parent: parent) {
            selectedTagName = created
        }
        cancelInlineMode()
    }

    private func startRename(_ tag: String) {
        draftText = MediaCategory.localizedTag(tag, in: lang)
        inlineMode = .renamingTag(tag)
    }

    private func commitRename(from oldTag: String) {
        if let replacement = TagInputParser.validatedRename(from: oldTag, draft: draftText, in: lang),
           let updated = store.renameTag(from: oldTag, to: replacement) {
            selectedTagName = updated
        }
        cancelInlineMode()
    }

    private func requestDelete(_ tag: String) {
        let nestedCount = store.nestedChildCount(for: tag)
        let itemCount = store.usageCount(forTag: tag, includeDescendants: true)
        if nestedCount == 0 && itemCount == 0 {
            cancelInlineMode()
            store.deleteTag(tag)
            if let selectedTagName, MediaCategory.tagsMatch(selectedTagName, tag) {
                self.selectedTagName = nil
            }
        } else {
            draftText = ""
            inlineMode = .confirmingDeleteTag(tag)
        }
    }
}
