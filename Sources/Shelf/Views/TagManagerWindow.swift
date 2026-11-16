import AppKit
import SwiftUI

private final class EscapeClosableWindow: NSWindow {
    var shouldCloseOnEscape: (() -> Bool)?

    override func cancelOperation(_ sender: Any?) {
        if shouldCloseOnEscape?() ?? true {
            close()
        }
    }
}

@MainActor
final class TagWindowController: NSObject, NSWindowDelegate {
    static let shared = TagWindowController()

    private var window: EscapeClosableWindow?
    private weak var store: LibraryStore?
    private nonisolated(unsafe) var windowCloseObserver: NSObjectProtocol?
    private var shouldCloseOnEscapeHandler: (() -> Bool)?

    private override init() {
        super.init()
    }

    deinit {
        if let windowCloseObserver {
            NotificationCenter.default.removeObserver(windowCloseObserver)
        }
    }

    func show(store: LibraryStore) {
        self.store = store
        installWindowObserverIfNeeded()

        if let existing = window {
            updateRootView(in: existing, store: store)
            existing.title = store.language.tr("管理标签", "Manage Tags")
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let created = EscapeClosableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 410, height: 520),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        created.isReleasedWhenClosed = false
        created.minSize = NSSize(width: 340, height: 380)
        created.title = store.language.tr("管理标签", "Manage Tags")
        created.delegate = self
        created.shouldCloseOnEscape = { [weak self] in
            self?.shouldCloseOnEscapeHandler?() ?? true
        }
        updateRootView(in: created, store: store)

        if let mainWindow = mainLibraryWindow(excluding: created) {
            let mainFrame = mainWindow.frame
            let size = created.frame.size
            let origin = NSPoint(
                x: mainFrame.midX - size.width * 0.5,
                y: mainFrame.midY - size.height * 0.5
            )
            created.setFrameOrigin(origin)
        } else {
            created.center()
        }

        self.window = created
        created.makeKeyAndOrderFront(nil)
    }

    func toggle(store: LibraryStore) {
        if let window, window.isVisible {
            window.close()
        } else {
            show(store: store)
        }
    }

    func focusMainLibraryWindow() {
        focusMainWindow()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        store?.isTagWindowKey = true
    }

    func windowDidResignKey(_ notification: Notification) {
        store?.isTagWindowKey = false
    }

    func windowWillClose(_ notification: Notification) {
        store?.isTagWindowKey = false
    }

    private func updateRootView(in window: EscapeClosableWindow, store: LibraryStore) {
        let rootView = TagManagerView(
            onFilterApplied: { [weak self] in
                self?.focusMainWindow()
            },
            onUpdateTitle: { [weak window] title in
                window?.title = title
            },
            registerEscapeHandler: { [weak self] handler in
                self?.shouldCloseOnEscapeHandler = handler
            }
        )
        .environment(store)

        if let hosting = window.contentView as? NSHostingView<AnyView> {
            hosting.rootView = AnyView(rootView)
        } else {
            let hosting = NSHostingView(rootView: AnyView(rootView))
            window.contentView = hosting
        }
    }

    private func focusMainWindow() {
        if let main = mainLibraryWindow(excluding: window) {
            main.makeKeyAndOrderFront(nil)
        }
    }

    private func mainLibraryWindow(excluding excluded: NSWindow?) -> NSWindow? {
        NSApp.windows.first { candidate in
            candidate !== excluded
                && candidate.isVisible
                && candidate.canBecomeMain
                && !candidate.isSheet
                && candidate.level == .normal
        }
    }

    private func installWindowObserverIfNeeded() {
        guard windowCloseObserver == nil else { return }
        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let closed = notification.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                guard let self, let tagWindow = self.window, closed !== tagWindow, tagWindow.isVisible else { return }
                let anotherMainRemains = NSApp.windows.contains { candidate in
                    candidate !== tagWindow
                        && candidate !== closed
                        && candidate.isVisible
                        && candidate.canBecomeMain
                        && !candidate.isSheet
                        && candidate.level == .normal
                }
                if !anotherMainRemains && closed.canBecomeMain && !closed.isSheet && closed.level == .normal {
                    tagWindow.close()
                }
            }
        }
    }
}

struct TagManagerView: View {
    @Environment(LibraryStore.self) private var store

    let onFilterApplied: () -> Void
    let onUpdateTitle: (String) -> Void
    let registerEscapeHandler: ((@escaping () -> Bool) -> Void)

    @State private var filterText: String = ""
    @State private var collapsedIDs: Set<String> = []
    @State private var collapsedCategoryIDs: Set<String> = []
    @State private var selectedTagName: String? = nil
    @State private var hoveredTagID: String? = nil
    @State private var hoveredCategoryID: String? = nil

    @State private var creatingCategory: Bool = false
    @State private var newCategoryDraft: String = ""
    @State private var creatingInCategory: String? = nil

    @State private var creatingUnderParent: String?? = nil
    @State private var newTagDraft: String = ""

    @State private var renamingTag: String? = nil
    @State private var renameDraft: String = ""

    @State private var renamingCategory: String? = nil
    @State private var renameCategoryDraft: String = ""

    @State private var pendingDeleteTag: String? = nil
    @State private var pendingDeleteCategory: String? = nil
    @State private var dropTargetRowID: String? = nil
    @State private var dropTargetCategoryID: String? = nil
    @State private var isRootDropTargeted: Bool = false

    private var lang: AppLanguage { store.language }

    private var trimmedFilter: String {
        filterText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

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

            if let target = pendingDeleteTag {
                deleteConfirmationBanner(for: target)
                Divider()
            } else if let targetCat = pendingDeleteCategory {
                deleteCategoryConfirmationBanner(for: targetCat)
                Divider()
            }

            if trimmedFilter.isEmpty {
                if groupedSections.isEmpty && !creatingCategory && creatingUnderParent == nil {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            if creatingCategory {
                                inlineCreateCategoryRow()
                            }

                            if case .some(nil) = creatingUnderParent, creatingInCategory == nil {
                                inlineCreateRow(depth: 0, category: nil, parent: nil)
                            }

                            ForEach(groupedSections) { section in
                                categoryHeader(section)

                                let isCreatingHere: Bool = {
                                    if case .some(nil) = creatingUnderParent {
                                        if let cat = section.category, let targetCat = creatingInCategory {
                                            return MediaCategory.tagsMatch(cat, targetCat)
                                        }
                                    }
                                    return false
                                }()

                                if isCreatingHere {
                                    inlineCreateRow(depth: 0, category: section.category, parent: nil)
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

                                            if case .some(.some(let parentName)) = creatingUnderParent,
                                               MediaCategory.tagsMatch(parentName, row.node.name) {
                                                inlineCreateRow(depth: row.depth + 1, category: row.category, parent: row.node.name)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        .padding(10)
                    }
                }
            } else {
                if visibleRows.isEmpty && creatingUnderParent == nil {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(visibleRows) { row in
                                tagRow(row)

                                if case .some(.some(let parentName)) = creatingUnderParent,
                                   MediaCategory.tagsMatch(parentName, row.node.name) {
                                    inlineCreateRow(depth: row.depth + 1, category: row.category, parent: row.node.name)
                                }
                            }
                        }
                        .padding(10)
                    }
                }
            }

            Divider()
            footerBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            onUpdateTitle(lang.tr("管理标签", "Manage Tags"))
            registerEscapeHandler {
                if renamingCategory != nil {
                    renamingCategory = nil
                    return false
                }
                if creatingCategory {
                    creatingCategory = false
                    newCategoryDraft = ""
                    return false
                }
                if renamingTag != nil {
                    renamingTag = nil
                    return false
                }
                if creatingUnderParent != nil {
                    creatingUnderParent = nil
                    creatingInCategory = nil
                    newTagDraft = ""
                    return false
                }
                if pendingDeleteTag != nil {
                    pendingDeleteTag = nil
                    return false
                }
                if pendingDeleteCategory != nil {
                    pendingDeleteCategory = nil
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

    private var headerToolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)

                SearchCommandTextField(
                    placeholder: lang.tr("筛选标签…", "Filter tags…"),
                    text: $filterText,
                    autoFocus: false,
                    font: .systemFont(ofSize: 12.5),
                    onEscape: {
                        filterText = ""
                    }
                )
                .frame(height: 18)

                if !filterText.isEmpty {
                    Button {
                        filterText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.11), lineWidth: 0.7)
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
            .buttonStyle(
                ShelfButtonStyle(
                    variant: .primary,
                    horizontalPadding: 10,
                    verticalPadding: 5,
                    cornerRadius: 7
                )
            )

            Button {
                beginCreatingCategory()
            } label: {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .buttonStyle(
                ShelfButtonStyle(
                    variant: .secondary,
                    horizontalPadding: 8,
                    verticalPadding: 5,
                    cornerRadius: 7
                )
            )
            .help(lang.tr("新建标签分类", "New Tag Category"))

            Button {
                beginCreatingTag(inCategory: nil, under: selectedExistingTag)
            } label: {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .buttonStyle(
                ShelfButtonStyle(
                    variant: .secondary,
                    horizontalPadding: 8,
                    verticalPadding: 5,
                    cornerRadius: 7
                )
            )
            .disabled(selectedExistingTag == nil)
            .help(lang.tr("在选中标签下新建子标签", "New subtag under selection"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func deleteConfirmationBanner(for target: String) -> some View {
        let shown = MediaCategory.localizedTag(target, in: lang)
        let nestedCount = store.nestedChildCount(for: target)
        let itemCount = store.usageCount(forTag: target, includeDescendants: true)
        let message: String = if nestedCount > 0 {
            lang.tr(
                "确定要删除「\(shown)」吗？其下嵌套的 \(nestedCount) 个子标签也将被删除，并从 \(itemCount) 部作品中移除。",
                "Delete “\(shown)”? The \(nestedCount) nested subtag(s) will also be deleted and removed from \(itemCount) item(s)."
            )
        } else {
            lang.tr(
                "确定要删除「\(shown)」吗？将从 \(itemCount) 部作品中移除。",
                "Delete “\(shown)”? It will be removed from \(itemCount) item(s)."
            )
        }

        return HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.system(size: 13))

            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 4)

            Button(lang.tr("删除", "Delete")) {
                store.deleteTag(target)
                pendingDeleteTag = nil
                if let selectedTagName, MediaCategory.tagsMatch(selectedTagName, target) {
                    self.selectedTagName = nil
                }
            }
            .buttonStyle(
                ShelfButtonStyle(
                    variant: .destructive,
                    horizontalPadding: 10,
                    verticalPadding: 4.5,
                    cornerRadius: 6
                )
            )
            .font(.system(size: 12, weight: .semibold))

            Button(lang.tr("取消", "Cancel")) {
                pendingDeleteTag = nil
            }
            .buttonStyle(
                ShelfButtonStyle(
                    variant: .subtle,
                    horizontalPadding: 8,
                    verticalPadding: 4.5,
                    cornerRadius: 6
                )
            )
            .font(.system(size: 12))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.red.opacity(0.08))
    }

    private func deleteCategoryConfirmationBanner(for targetCategory: String) -> some View {
        let shown = MediaCategory.localizedTag(targetCategory, in: lang)
        let tagCount = store.tagCount(inCategory: targetCategory)
        let message = lang.tr(
            "确定要删除分类「\(shown)」吗？其中的 \(tagCount) 个标签将移至「未分类」（不会从作品中移除）。",
            "Delete category “\(shown)”? Its \(tagCount) tag(s) will move to Uncategorized (items keep their tags)."
        )

        return HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.system(size: 13))

            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 4)

            Button(lang.tr("删除", "Delete")) {
                store.deleteTagCategory(targetCategory)
                pendingDeleteCategory = nil
            }
            .buttonStyle(
                ShelfButtonStyle(
                    variant: .destructive,
                    horizontalPadding: 10,
                    verticalPadding: 4.5,
                    cornerRadius: 6
                )
            )
            .font(.system(size: 12, weight: .semibold))

            Button(lang.tr("取消", "Cancel")) {
                pendingDeleteCategory = nil
            }
            .buttonStyle(
                ShelfButtonStyle(
                    variant: .subtle,
                    horizontalPadding: 8,
                    verticalPadding: 4.5,
                    cornerRadius: 6
                )
            )
            .font(.system(size: 12))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.red.opacity(0.08))
    }

    private func inlineCreateCategoryRow() -> some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .font(.system(size: 11.5))
                .foregroundStyle(Color.accentColor)
                .frame(width: 15)

            SearchCommandTextField(
                placeholder: lang.tr("输入新分类名称（如：风格、平台），回车创建…", "New category name, press Return…"),
                text: $newCategoryDraft,
                autoFocus: true,
                font: .systemFont(ofSize: 12.5),
                onSubmit: { _ in
                    commitNewCategory()
                },
                onEscape: {
                    creatingCategory = false
                    newCategoryDraft = ""
                }
            )
            .frame(height: 19)

            Button(lang.tr("创建", "Add")) {
                commitNewCategory()
            }
            .buttonStyle(
                ShelfButtonStyle(
                    variant: .primary,
                    horizontalPadding: 8,
                    verticalPadding: 3,
                    cornerRadius: 5
                )
            )
            .font(.system(size: 11, weight: .semibold))
            .disabled(newCategoryDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button(lang.tr("取消", "Cancel")) {
                creatingCategory = false
                newCategoryDraft = ""
            }
            .buttonStyle(
                ShelfButtonStyle(
                    variant: .subtle,
                    horizontalPadding: 6,
                    verticalPadding: 3,
                    cornerRadius: 5
                )
            )
            .font(.system(size: 11))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.accentColor.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 0.8)
        )
    }

    private func categoryHeader(_ section: TagCategorySection) -> some View {
        let isCollapsed = collapsedCategoryIDs.contains(section.id)
        let isHovered = hoveredCategoryID == section.id
        let isDropTarget = dropTargetCategoryID == section.id
        let isRenaming = section.category.map { cat in
            renamingCategory.map { MediaCategory.tagsMatch($0, cat) } ?? false
        } ?? false
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
                    text: $renameCategoryDraft,
                    autoFocus: true,
                    font: .systemFont(ofSize: 12, weight: .semibold),
                    onSubmit: { _ in
                        commitCategoryRename(from: cat)
                    },
                    onEscape: {
                        renamingCategory = nil
                    }
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
            if let cat = section.category {
                startCategoryRename(cat)
            }
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

    private func inlineCreateRow(depth: Int, category: String?, parent: String?) -> some View {
        HStack(spacing: 6) {
            if depth > 0 {
                Spacer()
                    .frame(width: CGFloat(depth) * 18)
            }
            Spacer().frame(width: 16)

            Image(systemName: "tag.fill")
                .font(.system(size: 11.5))
                .foregroundStyle(Color.accentColor)
                .frame(width: 15)

            SearchCommandTextField(
                placeholder: parent == nil
                    ? lang.tr("输入新标签名称，回车创建…", "New tag name, press Return…")
                    : lang.tr("输入子标签名称，回车创建…", "Subtag name, press Return…"),
                text: $newTagDraft,
                autoFocus: true,
                font: .systemFont(ofSize: 12.5),
                onSubmit: { _ in
                    commitNewTag(category: category, parent: parent)
                },
                onEscape: {
                    creatingUnderParent = nil
                    creatingInCategory = nil
                    newTagDraft = ""
                }
            )
            .frame(height: 19)

            Button(lang.tr("创建", "Add")) {
                commitNewTag(category: category, parent: parent)
            }
            .buttonStyle(
                ShelfButtonStyle(
                    variant: .primary,
                    horizontalPadding: 8,
                    verticalPadding: 3,
                    cornerRadius: 5
                )
            )
            .font(.system(size: 11, weight: .semibold))
            .disabled(newTagDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button(lang.tr("取消", "Cancel")) {
                creatingUnderParent = nil
                creatingInCategory = nil
                newTagDraft = ""
            }
            .buttonStyle(
                ShelfButtonStyle(
                    variant: .subtle,
                    horizontalPadding: 6,
                    verticalPadding: 3,
                    cornerRadius: 5
                )
            )
            .font(.system(size: 11))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.accentColor.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 0.8)
        )
    }

    private func tagRow(_ row: TagOutlineRow) -> some View {
        let isSelected = selectedTagName.map { MediaCategory.tagsMatch($0, row.node.name) } ?? false
        let isHovered = hoveredTagID == row.id
        let isDropTarget = dropTargetRowID == row.id
        let isCollapsed = collapsedIDs.contains(row.id)
        let isRenaming = renamingTag.map { MediaCategory.tagsMatch($0, row.node.name) } ?? false
        let count = store.usageCount(forTag: row.node.name, includeDescendants: true)

        return HStack(spacing: 6) {
            if trimmedFilter.isEmpty && row.depth > 0 {
                Spacer()
                    .frame(width: CGFloat(row.depth) * 18)
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
                Spacer()
                    .frame(width: 16)
            }

            Image(systemName: row.hasChildren ? "tag.fill" : "tag")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .frame(width: 15)

            if isRenaming {
                SearchCommandTextField(
                    placeholder: lang.tr("标签名称", "Tag name"),
                    text: $renameDraft,
                    autoFocus: true,
                    font: .systemFont(ofSize: 12.5),
                    onSubmit: { _ in
                        commitRename(from: row.node.name)
                    },
                    onEscape: {
                        renamingTag = nil
                    }
                )
                .frame(height: 19)
            } else {
                Text(MediaCategory.localizedTag(row.node.name, in: lang))
                    .font(.system(size: 12.5, weight: row.hasChildren ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if !trimmedFilter.isEmpty && !row.ancestors.isEmpty {
                    Text(TagCatalog.formattedBreadcrumb(ancestors: row.ancestors, language: lang))
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
                .strokeBorder(
                    isDropTarget ? Color.accentColor : Color.clear,
                    lineWidth: 1.2
                )
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
        .contextMenu {
            rowContextMenu(row)
        }
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
                        collapsedCategoryIDs.remove(category.lowercased())
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

        let siblings = TagCatalog.children(of: row.node.parent, in: store.tagNodes)
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
            Text(
                trimmedFilter.isEmpty
                    ? lang.tr("暂无标签", "No Tags Yet")
                    : lang.tr("没有匹配的标签", "No Matching Tags")
            )
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

    // MARK: - Actions

    private func toggleCollapse(_ id: String) {
        if collapsedIDs.contains(id) {
            collapsedIDs.remove(id)
        } else {
            collapsedIDs.insert(id)
        }
    }

    private func beginCreatingCategory() {
        renamingTag = nil
        renamingCategory = nil
        creatingUnderParent = nil
        creatingInCategory = nil
        pendingDeleteTag = nil
        pendingDeleteCategory = nil
        filterText = ""
        newCategoryDraft = ""
        creatingCategory = true
    }

    private func commitNewCategory() {
        let trimmed = newCategoryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            creatingCategory = false
            newCategoryDraft = ""
            return
        }
        store.addTagCategory(trimmed)
        creatingCategory = false
        newCategoryDraft = ""
    }

    private func startCategoryRename(_ category: String) {
        creatingCategory = false
        creatingUnderParent = nil
        renamingTag = nil
        pendingDeleteTag = nil
        pendingDeleteCategory = nil
        renamingCategory = category
        renameCategoryDraft = MediaCategory.localizedTag(category, in: lang)
    }

    private func commitCategoryRename(from oldCategory: String) {
        let trimmed = renameCategoryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            renamingCategory = nil
            return
        }
        if trimmed != oldCategory && trimmed != MediaCategory.localizedTag(oldCategory, in: lang) {
            store.renameTagCategory(from: oldCategory, to: trimmed)
        }
        renamingCategory = nil
    }

    private func requestDeleteCategory(_ category: String) {
        renamingTag = nil
        renamingCategory = nil
        creatingCategory = false
        creatingUnderParent = nil
        pendingDeleteTag = nil
        if store.tagCount(inCategory: category) == 0 {
            store.deleteTagCategory(category)
        } else {
            pendingDeleteCategory = category
        }
    }

    private func beginCreatingTag(inCategory category: String?, under parent: String?) {
        renamingTag = nil
        renamingCategory = nil
        creatingCategory = false
        pendingDeleteTag = nil
        pendingDeleteCategory = nil
        newTagDraft = ""
        if let parent {
            filterText = ""
            collapsedIDs.remove(MediaCategory.canonicalTag(parent).lowercased())
            creatingInCategory = category
            creatingUnderParent = .some(parent)
        } else {
            if let category {
                collapsedCategoryIDs.remove(category.lowercased())
            }
            creatingInCategory = category
            creatingUnderParent = .some(nil)
        }
    }

    private func commitNewTag(category: String?, parent: String?) {
        let trimmed = newTagDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            creatingUnderParent = nil
            creatingInCategory = nil
            newTagDraft = ""
            return
        }
        if let created = store.addTag(trimmed, category: category, parent: parent) {
            selectedTagName = created
        }
        creatingUnderParent = nil
        creatingInCategory = nil
        newTagDraft = ""
    }

    private func startRename(_ tag: String) {
        creatingUnderParent = nil
        pendingDeleteTag = nil
        renamingTag = tag
        renameDraft = MediaCategory.localizedTag(tag, in: lang)
    }

    private func commitRename(from oldTag: String) {
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            renamingTag = nil
            return
        }
        if trimmed != oldTag && trimmed != MediaCategory.localizedTag(oldTag, in: lang) {
            if let updated = store.renameTag(from: oldTag, to: trimmed) {
                selectedTagName = updated
            }
        }
        renamingTag = nil
    }

    private func requestDelete(_ tag: String) {
        renamingTag = nil
        creatingUnderParent = nil
        let nestedCount = store.nestedChildCount(for: tag)
        let itemCount = store.usageCount(forTag: tag, includeDescendants: true)
        if nestedCount == 0 && itemCount == 0 {
            store.deleteTag(tag)
            if let selectedTagName, MediaCategory.tagsMatch(selectedTagName, tag) {
                self.selectedTagName = nil
            }
        } else {
            pendingDeleteTag = tag
        }
    }
}
