import AppKit
import SwiftUI

/// Things 3 `⇧⌘T` searchable checklist tag picker (for detail popover & floating overlay).
struct TagPickerContentView: View {
    private enum Target {
        case item(UUID)
        case binding(Binding<[String]>)
    }

    private enum InlineMode: Equatable {
        case none
        case creatingCategory
        case renamingCategory(String)
    }

    private enum PickerRow: Identifiable {
        case existing(TagOutlineRow)
        case create(String)

        var id: String {
            switch self {
            case .existing(let row): return "tag:\(row.id)"
            case .create(let name): return "create:\(MediaCategory.tagMatchKey(name))"
            }
        }
    }

    let store: LibraryStore
    private let target: Target
    let language: AppLanguage
    var headerTitle: String? = nil
    var showCloseButton: Bool = false
    let onClose: () -> Void

    @State private var query: String = ""
    @State private var highlightedIndex: Int = 0
    @State private var hoveredID: String? = nil
    @State private var dropTargetCategoryID: String? = nil
    @State private var dropTargetTagID: String? = nil
    @State private var inlineMode: InlineMode = .none
    @State private var inlineDraft: String = ""

    init(
        store: LibraryStore,
        itemID: UUID,
        language: AppLanguage,
        headerTitle: String? = nil,
        showCloseButton: Bool = false,
        onClose: @escaping () -> Void
    ) {
        self.store = store
        self.target = .item(itemID)
        self.language = language
        self.headerTitle = headerTitle
        self.showCloseButton = showCloseButton
        self.onClose = onClose
    }

    init(
        store: LibraryStore,
        selectedTags: Binding<[String]>,
        language: AppLanguage,
        headerTitle: String? = nil,
        showCloseButton: Bool = false,
        onClose: @escaping () -> Void
    ) {
        self.store = store
        self.target = .binding(selectedTags)
        self.language = language
        self.headerTitle = headerTitle
        self.showCloseButton = showCloseButton
        self.onClose = onClose
    }

    private var currentTags: [String] {
        switch target {
        case .item(let id): return store.item(withID: id)?.tags ?? []
        case .binding(let binding): return binding.wrappedValue
        }
    }

    private var trimmedQuery: String { query.trimmed }

    private var groupedSections: [TagCategorySection] {
        TagCatalog.groupedOutline(
            categories: store.tagCategories,
            nodes: store.tagNodes,
            includeEmptyCategories: true
        )
    }

    private var pickerRows: [PickerRow] {
        if trimmedQuery.isEmpty {
            return groupedSections.flatMap(\.rows).map { .existing($0) }
        }
        let matched = TagCatalog.searchRows(matching: trimmedQuery, in: store.tagNodes)
        var rows = matched.map { PickerRow.existing($0) }
        if !store.tagExists(trimmedQuery) {
            rows.append(.create(trimmedQuery))
        }
        return rows
    }

    private func isTagSelected(_ name: String) -> Bool {
        currentTags.contains { MediaCategory.tagsMatch($0, name) }
    }

    var body: some View {
        let rows = pickerRows
        let safeIndex = rows.isEmpty ? 0 : min(max(highlightedIndex, 0), rows.count - 1)
        let isCreatingCategory = inlineMode == .creatingCategory

        VStack(spacing: 0) {
            if let headerTitle {
                HStack(spacing: 8) {
                    Text(headerTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    if showCloseButton {
                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 20, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                ShelfHairline()
            }

            ShelfSearchBar(
                placeholder: language.tr("搜索或新建标签…", "Add or create tag…"),
                text: $query,
                autoFocus: true,
                font: .systemFont(ofSize: 13),
                iconSize: 12,
                fieldHeight: 20,
                horizontalPadding: 12,
                verticalPadding: 9,
                showsChrome: false,
                onMoveUp: {
                    guard !rows.isEmpty else { return }
                    highlightedIndex = (safeIndex - 1 + rows.count) % rows.count
                },
                onMoveDown: {
                    guard !rows.isEmpty else { return }
                    highlightedIndex = (safeIndex + 1) % rows.count
                },
                onSubmit: { _ in
                    guard !rows.isEmpty else {
                        onClose()
                        return
                    }
                    activateRow(rows[safeIndex])
                },
                onEscape: onClose
            )

            Divider()

            if rows.isEmpty && !isCreatingCategory && (!trimmedQuery.isEmpty || groupedSections.isEmpty) {
                Text(language.tr("暂无标签，输入名称回车新建", "Type a tag name to create"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            if isCreatingCategory {
                                TagInlineCreateRow(
                                    icon: "folder.fill",
                                    placeholder: language.tr("输入分类名称，回车创建…", "Category name, press Return…"),
                                    draft: $inlineDraft,
                                    language: language,
                                    compact: true,
                                    onCommit: commitNewCategory,
                                    onCancel: cancelInlineMode
                                )
                                .padding(.bottom, 3)
                            }

                            if trimmedQuery.isEmpty {
                                let indexByID = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($1.id, $0) })
                                ForEach(groupedSections) { section in
                                    categoryHeaderView(section)
                                    if section.rows.isEmpty {
                                        Text(language.tr("拖拽标签至此分类", "Drag tags here"))
                                            .font(.system(size: 11))
                                            .foregroundStyle(.tertiary)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 4)
                                    } else {
                                        ForEach(section.rows) { outlineRow in
                                            let pickerRow = PickerRow.existing(outlineRow)
                                            let idx = indexByID[pickerRow.id] ?? -1
                                            rowView(pickerRow, isHighlighted: idx == safeIndex)
                                                .id(pickerRow.id)
                                        }
                                    }
                                }
                            } else {
                                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                                    rowView(row, isHighlighted: index == safeIndex)
                                        .id(row.id)
                                }
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 290)
                    .onChange(of: query) { _, _ in
                        highlightedIndex = 0
                    }
                    .onChange(of: highlightedIndex) { _, newIdx in
                        guard rows.indices.contains(newIdx) else { return }
                        proxy.scrollTo(rows[newIdx].id)
                    }
                }
            }

            Divider()

            HStack(spacing: 6) {
                Text(
                    currentTags.isEmpty
                        ? language.tr("未设置标签", "No tags assigned")
                        : language.tr("已选 \(currentTags.count) 个标签", "\(currentTags.count) selected")
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)

                Spacer(minLength: 4)

                Button {
                    if isCreatingCategory {
                        cancelInlineMode()
                    } else {
                        inlineDraft = ""
                        inlineMode = .creatingCategory
                    }
                } label: {
                    Label(language.tr("新建分类", "New Category"), systemImage: "folder.badge.plus")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(ShelfButtonStyle(variant: .subtle, horizontalPadding: 7, verticalPadding: 3, cornerRadius: 5))

                Button {
                    onClose()
                    TagWindowController.shared.show(store: store)
                } label: {
                    Label(language.tr("管理标签…", "Manage…"), systemImage: "slider.horizontal.3")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(ShelfButtonStyle(variant: .subtle, horizontalPadding: 7, verticalPadding: 3, cornerRadius: 5))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private func categoryHeaderView(_ section: TagCategorySection) -> some View {
        let isDropTarget = dropTargetCategoryID == section.id
        let isRenaming: Bool = {
            if case .renamingCategory(let target) = inlineMode, let cat = section.category {
                return MediaCategory.tagsMatch(target, cat)
            }
            return false
        }()
        let sectionTitle = section.category.map { MediaCategory.localizedTag($0, in: language) }
            ?? language.tr("未分类", "Uncategorized")

        HStack(spacing: 5) {
            if isRenaming, let cat = section.category {
                SearchCommandTextField(
                    placeholder: language.tr("分类名称", "Category name"),
                    text: $inlineDraft,
                    autoFocus: true,
                    font: .systemFont(ofSize: 11.5, weight: .semibold),
                    onSubmit: { _ in
                        if let replacement = TagInputParser.validatedRename(from: cat, draft: inlineDraft, in: language) {
                            store.renameTagCategory(from: cat, to: replacement)
                        }
                        cancelInlineMode()
                    },
                    onEscape: cancelInlineMode
                )
                .frame(height: 16)
            } else {
                Text(sectionTitle)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(isDropTarget ? Color.accentColor : .secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .padding(.top, 4)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isDropTarget ? Color.accentColor.opacity(0.14) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(isDropTarget ? Color.accentColor : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { droppedItems, _ in
            guard let dropped = droppedItems.first, store.tagExists(dropped) else { return false }
            store.setTagCategory(dropped, category: section.category)
            return true
        } isTargeted: { targeted in
            dropTargetCategoryID = targeted ? section.id : (dropTargetCategoryID == section.id ? nil : dropTargetCategoryID)
        }
        .contextMenu {
            if let cat = section.category {
                Button {
                    inlineDraft = MediaCategory.localizedTag(cat, in: language)
                    inlineMode = .renamingCategory(cat)
                } label: {
                    Label(language.tr("重命名分类…", "Rename Category…"), systemImage: "pencil")
                }

                Divider()

                Button(role: .destructive) {
                    store.deleteTagCategory(cat)
                } label: {
                    Label(language.tr("删除分类", "Delete Category"), systemImage: "trash")
                }
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: PickerRow, isHighlighted: Bool) -> some View {
        let isHovered = hoveredID == row.id
        let button = Button {
            activateRow(row)
        } label: {
            switch row {
            case .existing(let outline):
                let selected = isTagSelected(outline.node.name)
                HStack(spacing: 7) {
                    if trimmedQuery.isEmpty && outline.depth > 0 {
                        Spacer().frame(width: CGFloat(outline.depth) * 14)
                    }

                    Image(systemName: outline.hasChildren ? "tag.fill" : "tag")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                        .frame(width: 14)

                    Text(MediaCategory.localizedTag(outline.node.name, in: language))
                        .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    let breadcrumb = outline.fullBreadcrumb(in: language)
                    if !trimmedQuery.isEmpty && !breadcrumb.isEmpty {
                        Text(breadcrumb)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    if selected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(rowBackground(isHighlighted: isHighlighted, isHovered: isHovered))
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            case .create(let newName):
                HStack(spacing: 7) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 14)

                    Text(language.tr("新建标签「\(newName)」", "New Tag “\(newName)”"))
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .lineLimit(1)

                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(rowBackground(isHighlighted: isHighlighted, isHovered: isHovered))
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.10), value: isHighlighted)
        .animation(.easeOut(duration: 0.10), value: isHovered)
        .onHover { hovering in
            hoveredID = hovering ? row.id : (hoveredID == row.id ? nil : hoveredID)
        }

        if case .existing(let outline) = row {
            let isDropTarget = dropTargetTagID == row.id
            button
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isDropTarget ? Color.accentColor : Color.clear, lineWidth: 1)
                )
                .draggable(outline.node.name)
                .dropDestination(for: String.self) { droppedItems, _ in
                    guard let dropped = droppedItems.first,
                          TagCatalog.canSetParent(of: dropped, to: outline.node.name, in: store.tagNodes) else {
                        return false
                    }
                    store.setTagParent(dropped, parent: outline.node.name)
                    return true
                } isTargeted: { targeted in
                    dropTargetTagID = targeted ? row.id : (dropTargetTagID == row.id ? nil : dropTargetTagID)
                }
        } else {
            button
        }
    }

    private func rowBackground(isHighlighted: Bool, isHovered: Bool) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(
                isHighlighted
                    ? Color.accentColor.opacity(0.16)
                    : (isHovered ? Color.primary.opacity(0.06) : Color.clear)
            )
    }

    private func cancelInlineMode() {
        inlineMode = .none
        inlineDraft = ""
    }

    private func commitNewCategory() {
        let trimmed = inlineDraft.trimmed
        if !trimmed.isEmpty {
            store.addTagCategory(trimmed)
        }
        cancelInlineMode()
    }

    private func activateRow(_ row: PickerRow) {
        switch row {
        case .existing(let outline):
            toggleTag(outline.node.name)
        case .create(let rawName):
            for piece in TagInputParser.splitBatchInput(rawName) {
                if let created = store.addTag(piece), !isTagSelected(created) {
                    toggleTag(created)
                }
            }
        }
        if !query.isEmpty {
            query = ""
        }
    }

    private func toggleTag(_ rawTag: String) {
        switch target {
        case .item(let id):
            store.toggleItemTag(rawTag, for: id)
        case .binding(let binding):
            if let idx = binding.wrappedValue.firstIndex(where: { MediaCategory.tagsMatch($0, rawTag) }) {
                binding.wrappedValue.remove(at: idx)
            } else {
                let canonical = MediaCategory.canonicalTag(rawTag)
                guard !canonical.isEmpty else { return }
                binding.wrappedValue = MediaCategory.normalizeTags(binding.wrappedValue + [canonical])
            }
        }
    }
}

/// Floating centered-upper `⇧⌘T` tag picker overlay for the selected poster card.
struct TagPickerOverlay: View {
    let store: LibraryStore
    let itemID: UUID
    let language: AppLanguage
    let onDismiss: () -> Void

    var body: some View {
        let itemTitle = store.item(withID: itemID)?.quotedTitle(in: language)
        let header = itemTitle.map {
            language.tr("为 \($0) 设置标签", "Tags for \($0)")
        }

        ModalOverlayContainer(width: 300, topPadding: 64, cornerRadius: 12, backdropOpacity: 0.18, showsBackdrop: false, onDismiss: onDismiss) {
            TagPickerContentView(
                store: store,
                itemID: itemID,
                language: language,
                headerTitle: header,
                showCloseButton: true,
                onClose: onDismiss
            )
        }
    }
}
