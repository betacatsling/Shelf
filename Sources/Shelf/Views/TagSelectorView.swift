import AppKit
import SwiftUI

struct ShelfFlowLayout: Layout {
    var alignment: HorizontalAlignment = .leading
    var horizontalSpacing: CGFloat = 6
    var verticalSpacing: CGFloat = 6

    private struct Item {
        let index: Int
        let size: CGSize
        let x: CGFloat
    }

    private struct Row {
        var items: [Item] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let (rows, totalHeight) = arrange(subviews: subviews, maxWidth: maxWidth)
        let contentWidth = rows.map(\.width).max() ?? 0
        let width = maxWidth.isFinite ? max(maxWidth, contentWidth) : contentWidth
        return CGSize(width: width, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (rows, _) = arrange(subviews: subviews, maxWidth: bounds.width)
        var y = bounds.minY
        for row in rows {
            let startX: CGFloat
            switch alignment {
            case .center:
                startX = bounds.minX + max(0, (bounds.width - row.width) * 0.5)
            case .trailing:
                startX = bounds.maxX - row.width
            default:
                startX = bounds.minX
            }

            for item in row.items {
                let x = startX + item.x
                let itemY = y + (row.height - item.size.height) * 0.5
                subviews[item.index].place(
                    at: CGPoint(x: x, y: itemY),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: item.size.width, height: item.size.height)
                )
            }
            y += row.height + verticalSpacing
        }
    }

    private func arrange(subviews: Subviews, maxWidth: CGFloat) -> ([Row], CGFloat) {
        let limit = maxWidth > 0 ? maxWidth : .infinity
        let childProposal = ProposedViewSize(width: limit.isFinite ? limit : nil, height: nil)

        var rows: [Row] = []
        var current = Row()

        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(childProposal)
            let nextX = current.items.isEmpty ? 0 : current.width + horizontalSpacing
            if !current.items.isEmpty && nextX + size.width > limit {
                rows.append(current)
                current = Row(
                    items: [Item(index: index, size: size, x: 0)],
                    width: size.width,
                    height: size.height
                )
            } else {
                current.items.append(Item(index: index, size: size, x: nextX))
                current.width = nextX + size.width
                current.height = max(current.height, size.height)
            }
        }

        if !current.items.isEmpty {
            rows.append(current)
        }

        let totalHeight = rows.enumerated().reduce(CGFloat(0)) { partial, entry in
            partial + entry.element.height + (entry.offset > 0 ? verticalSpacing : 0)
        }
        return (rows, totalHeight)
    }
}

/// AppKit-backed single-line input field that captures navigation keys (`↑`, `↓`, `↵`, `Esc`, empty `⌫`)
/// while preserving Chinese IME marked text composition.
struct SearchCommandTextField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    var autoFocus: Bool = false
    var font: NSFont = .systemFont(ofSize: 13)
    var onMoveUp: () -> Void = {}
    var onMoveDown: () -> Void = {}
    var onSubmit: (NSEvent.ModifierFlags) -> Void = { _ in }
    var onEscape: () -> Void = {}
    var onDeleteBackwardWhenEmpty: (() -> Void)? = nil
    var interceptSubmitWhenEmpty: Bool = true
    var interceptEscapeWhenEmpty: Bool = true

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = font
        field.placeholderString = placeholder
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.parent = self
        if nsView.placeholderString != placeholder {
            nsView.placeholderString = placeholder
        }
        if nsView.font != font {
            nsView.font = font
        }
        let hasMarked = (nsView.currentEditor() as? NSTextView)?.hasMarkedText() ?? false
        if !hasMarked && nsView.stringValue != text {
            nsView.stringValue = text
        }
        if autoFocus && !context.coordinator.didAutoFocus, let window = nsView.window {
            context.coordinator.didAutoFocus = true
            DispatchQueue.main.async { [weak nsView, weak window] in
                guard let nsView, let window, window.firstResponder !== nsView.currentEditor() else { return }
                window.makeFirstResponder(nsView)
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchCommandTextField
        var didAutoFocus = false

        init(parent: SearchCommandTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            if parent.text != field.stringValue {
                parent.text = field.stringValue
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if textView.hasMarkedText() {
                return false
            }
            if commandSelector == #selector(NSResponder.moveUp(_:)) {
                parent.onMoveUp()
                return true
            }
            if commandSelector == #selector(NSResponder.moveDown(_:)) {
                parent.onMoveDown()
                return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if control.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !parent.interceptSubmitWhenEmpty {
                    return false
                }
                let flags = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
                parent.onSubmit(flags)
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                if control.stringValue.isEmpty && !parent.interceptEscapeWhenEmpty {
                    return false
                }
                parent.onEscape()
                return true
            }
            if commandSelector == #selector(NSResponder.deleteBackward(_:)),
               control.stringValue.isEmpty,
               let onDelete = parent.onDeleteBackwardWhenEmpty {
                onDelete()
                return true
            }
            return false
        }
    }
}

/// Things 3 `⇧⌘T` searchable checklist tag picker (for detail popover & floating overlay).
struct TagPickerContentView: View {
    private enum Target {
        case item(UUID)
        case binding(Binding<[String]>)
    }

    private enum PickerRow: Identifiable {
        case existing(TagOutlineRow)
        case create(String)

        var id: String {
            switch self {
            case .existing(let row): return "tag:\(row.id)"
            case .create(let name): return "create:\(name.lowercased())"
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
    @State private var isCreatingCategory: Bool = false
    @State private var newCategoryDraft: String = ""
    @State private var renamingCategory: String? = nil
    @State private var renameCategoryDraft: String = ""

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
        case .item(let id):
            return store.item(withID: id)?.tags ?? []
        case .binding(let binding):
            return binding.wrappedValue
        }
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var groupedSections: [TagCategorySection] {
        TagCatalog.groupedOutline(
            categories: store.tagCategories,
            nodes: store.tagNodes,
            includeEmptyCategories: true
        )
    }

    private var pickerRows: [PickerRow] {
        if trimmedQuery.isEmpty {
            return groupedSections.flatMap(\.rows).map { PickerRow.existing($0) }
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
                Divider()
            }

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)

                SearchCommandTextField(
                    placeholder: language.tr("搜索或新建标签…", "Add or create tag…"),
                    text: $query,
                    autoFocus: true,
                    font: .systemFont(ofSize: 13),
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
                .frame(height: 20)

                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

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
                                inlineCreateCategoryRow()
                            }

                            if trimmedQuery.isEmpty {
                                let indexByID = Dictionary(
                                    uniqueKeysWithValues: rows.enumerated().map { ($1.id, $0) }
                                )
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
                    .frame(height: min(CGFloat(rows.count) * 29 + (trimmedQuery.isEmpty ? CGFloat(groupedSections.count) * 26 : 0) + (isCreatingCategory ? 36 : 0) + 12, 290))
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
                    newCategoryDraft = ""
                    isCreatingCategory.toggle()
                } label: {
                    Label(language.tr("新建分类", "New Category"), systemImage: "folder.badge.plus")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(
                    ShelfButtonStyle(
                        variant: .subtle,
                        horizontalPadding: 7,
                        verticalPadding: 3,
                        cornerRadius: 5
                    )
                )

                Button {
                    onClose()
                    TagWindowController.shared.show(store: store)
                } label: {
                    Label(language.tr("管理标签…", "Manage…"), systemImage: "slider.horizontal.3")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(
                    ShelfButtonStyle(
                        variant: .subtle,
                        horizontalPadding: 7,
                        verticalPadding: 3,
                        cornerRadius: 5
                    )
                )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private func categoryHeaderView(_ section: TagCategorySection) -> some View {
        let isDropTarget = dropTargetCategoryID == section.id
        let isRenaming = section.category.map { cat in
            renamingCategory.map { MediaCategory.tagsMatch($0, cat) } ?? false
        } ?? false
        let sectionTitle = section.category.map { MediaCategory.localizedTag($0, in: language) }
            ?? language.tr("未分类", "Uncategorized")

        HStack(spacing: 5) {
            if isRenaming, let cat = section.category {
                SearchCommandTextField(
                    placeholder: language.tr("分类名称", "Category name"),
                    text: $renameCategoryDraft,
                    autoFocus: true,
                    font: .systemFont(ofSize: 11.5, weight: .semibold),
                    onSubmit: { _ in
                        let trimmed = renameCategoryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            store.renameTagCategory(from: cat, to: trimmed)
                        }
                        renamingCategory = nil
                    },
                    onEscape: {
                        renamingCategory = nil
                    }
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
                    renameCategoryDraft = MediaCategory.localizedTag(cat, in: language)
                    renamingCategory = cat
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

    private func inlineCreateCategoryRow() -> some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color.accentColor)

            SearchCommandTextField(
                placeholder: language.tr("输入分类名称，回车创建…", "Category name, press Return…"),
                text: $newCategoryDraft,
                autoFocus: true,
                font: .systemFont(ofSize: 12),
                onSubmit: { _ in
                    commitNewCategory()
                },
                onEscape: {
                    isCreatingCategory = false
                    newCategoryDraft = ""
                }
            )
            .frame(height: 18)

            Button(language.tr("创建", "Add")) {
                commitNewCategory()
            }
            .buttonStyle(
                ShelfButtonStyle(
                    variant: .primary,
                    horizontalPadding: 7,
                    verticalPadding: 2.5,
                    cornerRadius: 5
                )
            )
            .font(.system(size: 10.5, weight: .semibold))
            .disabled(newCategoryDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button(language.tr("取消", "Cancel")) {
                isCreatingCategory = false
                newCategoryDraft = ""
            }
            .buttonStyle(
                ShelfButtonStyle(
                    variant: .subtle,
                    horizontalPadding: 5,
                    verticalPadding: 2.5,
                    cornerRadius: 5
                )
            )
            .font(.system(size: 10.5))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.accentColor.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 0.8)
        )
        .padding(.bottom, 3)
    }

    private func commitNewCategory() {
        let trimmed = newCategoryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            store.addTagCategory(trimmed)
        }
        isCreatingCategory = false
        newCategoryDraft = ""
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
                        Spacer()
                            .frame(width: CGFloat(outline.depth) * 14)
                    }

                    Image(systemName: outline.hasChildren ? "tag.fill" : "tag")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                        .frame(width: 14)

                    Text(MediaCategory.localizedTag(outline.node.name, in: language))
                        .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    let breadcrumbParts = (outline.category.map { [$0] } ?? []) + outline.ancestors
                    if !trimmedQuery.isEmpty && !breadcrumbParts.isEmpty {
                        Text(TagCatalog.formattedBreadcrumb(ancestors: breadcrumbParts, language: language))
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
                          store.tagExists(dropped),
                          !MediaCategory.tagsMatch(dropped, outline.node.name) else { return false }
                    store.setTagCategory(dropped, category: outline.category)
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

    private func activateRow(_ row: PickerRow) {
        switch row {
        case .existing(let outline):
            toggleTag(outline.node.name)
        case .create(let rawName):
            let pieces = rawName
                .components(separatedBy: CharacterSet(charactersIn: ",，;；"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            for piece in pieces {
                if let created = store.addTag(piece) {
                    if !isTagSelected(created) {
                        toggleTag(created)
                    }
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

        ZStack(alignment: .top) {
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)

            TagPickerContentView(
                store: store,
                itemID: itemID,
                language: language,
                headerTitle: header,
                showCloseButton: true,
                onClose: onDismiss
            )
            .frame(width: 300)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.9)
            )
            .shadow(color: .black.opacity(0.28), radius: 22, x: 0, y: 10)
            .padding(.top, 64)
        }
    }
}

/// Compact Things 3–style inline tag token field for `ItemEditorSheet`.
struct InlineTagField: View {
    let store: LibraryStore
    let category: MediaCategory
    @Binding var selectedTags: [String]
    let language: AppLanguage

    @State private var query: String = ""
    @State private var highlightedIndex: Int = 0
    @State private var showPickerPopover: Bool = false

    private enum Suggestion: Identifiable {
        case existing(TagOutlineRow)
        case create(String)

        var id: String {
            switch self {
            case .existing(let row): return "existing:\(row.id)"
            case .create(let name): return "create:\(name.lowercased())"
            }
        }
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var suggestions: [Suggestion] {
        guard !trimmedQuery.isEmpty else { return [] }
        let matched = TagCatalog.searchRows(matching: trimmedQuery, in: store.tagNodes)
            .filter { row in !selectedTags.contains { MediaCategory.tagsMatch($0, row.node.name) } }
            .prefix(6)
        var list = matched.map { Suggestion.existing($0) }
        if !store.tagExists(trimmedQuery) {
            list.append(.create(trimmedQuery))
        }
        return list
    }

    var body: some View {
        let currentSuggestions = suggestions
        let safeIdx = currentSuggestions.isEmpty ? 0 : min(max(highlightedIndex, 0), currentSuggestions.count - 1)

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(language.tr("标签（可选）", "Tags (Optional)"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                if !selectedTags.isEmpty {
                    Button(language.tr("清空", "Clear")) {
                        selectedTags.removeAll()
                    }
                    .buttonStyle(
                        ShelfButtonStyle(
                            variant: .subtle,
                            horizontalPadding: 6,
                            verticalPadding: 2,
                            cornerRadius: 5
                        )
                    )
                    .font(.system(size: 11))
                }

                Spacer()

                Button {
                    TagWindowController.shared.show(store: store)
                } label: {
                    Label(language.tr("管理标签…", "Manage Tags…"), systemImage: "slider.horizontal.3")
                        .font(.system(size: 11))
                }
                .buttonStyle(
                    ShelfButtonStyle(
                        variant: .subtle,
                        horizontalPadding: 6,
                        verticalPadding: 2,
                        cornerRadius: 5
                    )
                )
            }

            HStack(alignment: .center, spacing: 6) {
                ShelfFlowLayout(alignment: .leading, horizontalSpacing: 5, verticalSpacing: 5) {
                    ForEach(selectedTags, id: \.self) { tag in
                        HStack(spacing: 4) {
                            Text(MediaCategory.localizedTag(tag, in: language))
                                .font(.system(size: 11.5, weight: .medium))
                                .lineLimit(1)

                            Button {
                                removeTag(tag)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8.5, weight: .bold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 14, height: 14)
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.leading, 8)
                        .padding(.trailing, 5)
                        .padding(.vertical, 3.5)
                        .background(Color.accentColor.opacity(0.14), in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.32), lineWidth: 0.7))
                    }

                    SearchCommandTextField(
                        placeholder: selectedTags.isEmpty
                            ? language.tr("输入添加标签，回车确认…", "Type tag & press Return…")
                            : language.tr("添加更多标签…", "Add tag…"),
                        text: $query,
                        autoFocus: false,
                        font: .systemFont(ofSize: 12),
                        onMoveUp: {
                            guard !currentSuggestions.isEmpty else { return }
                            highlightedIndex = (safeIdx - 1 + currentSuggestions.count) % currentSuggestions.count
                        },
                        onMoveDown: {
                            guard !currentSuggestions.isEmpty else { return }
                            highlightedIndex = (safeIdx + 1) % currentSuggestions.count
                        },
                        onSubmit: { _ in
                            if !currentSuggestions.isEmpty {
                                applySuggestion(currentSuggestions[safeIdx])
                            }
                        },
                        onEscape: {
                            query = ""
                        },
                        onDeleteBackwardWhenEmpty: {
                            if !selectedTags.isEmpty {
                                selectedTags.removeLast()
                            }
                        },
                        interceptSubmitWhenEmpty: false,
                        interceptEscapeWhenEmpty: false
                    )
                    .frame(minWidth: 125, maxWidth: 210, minHeight: 20, maxHeight: 20)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    showPickerPopover.toggle()
                } label: {
                    Image(systemName: "tag")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(language.tr("从标签列表选择", "Browse tags"))
                .popover(isPresented: $showPickerPopover, arrowEdge: .bottom) {
                    TagPickerContentView(
                        store: store,
                        selectedTags: $selectedTags,
                        language: language
                    ) {
                        showPickerPopover = false
                    }
                    .frame(width: 270)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.8)
            )
            .onChange(of: query) { _, _ in
                highlightedIndex = 0
            }

            if !currentSuggestions.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(currentSuggestions.enumerated()), id: \.element.id) { index, suggestion in
                        suggestionRow(suggestion, isHighlighted: index == safeIdx)
                    }
                }
                .padding(5)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.8)
                )
            }
        }
    }

    @ViewBuilder
    private func suggestionRow(_ suggestion: Suggestion, isHighlighted: Bool) -> some View {
        Button {
            applySuggestion(suggestion)
        } label: {
            switch suggestion {
            case .existing(let row):
                HStack(spacing: 6) {
                    Image(systemName: row.hasChildren ? "tag.fill" : "tag")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    Text(MediaCategory.localizedTag(row.node.name, in: language))
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                    let breadcrumbParts = (row.category.map { [$0] } ?? []) + row.ancestors
                    if !breadcrumbParts.isEmpty {
                        Text(TagCatalog.formattedBreadcrumb(ancestors: breadcrumbParts, language: language))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isHighlighted ? Color.accentColor.opacity(0.16) : Color.clear)
                )
                .contentShape(Rectangle())

            case .create(let raw):
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.accentColor)
                    Text(language.tr("新建并添加「\(raw)」", "Create & add “\(raw)”"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isHighlighted ? Color.accentColor.opacity(0.16) : Color.clear)
                )
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
    }

    private func removeTag(_ tag: String) {
        selectedTags.removeAll { MediaCategory.tagsMatch($0, tag) }
    }

    private func applySuggestion(_ suggestion: Suggestion) {
        switch suggestion {
        case .existing(let row):
            selectedTags = MediaCategory.normalizeTags(selectedTags + [row.node.name])
        case .create(let raw):
            let pieces = raw
                .components(separatedBy: CharacterSet(charactersIn: ",，;；"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            for piece in pieces {
                if let created = store.addTag(piece) {
                    selectedTags = MediaCategory.normalizeTags(selectedTags + [created])
                }
            }
        }
        query = ""
    }
}
