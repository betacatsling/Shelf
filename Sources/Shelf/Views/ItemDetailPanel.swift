import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ItemDetailPanel: View {
    let item: MediaItem
    let isShowing: Bool
    let onReplaceCover: () -> Void
    let onClose: () -> Void

    @Environment(LibraryStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draftNotes: String
    @State private var isPosterHovered = false
    @State private var isTitleHovered = false
    @State private var isCategoryHovered = false
    @State private var isSubtagHovered = false
    @State private var isDeleteHovered = false
    @State private var isDropTargeted = false
    @State private var showDeleteConfirm = false

    @State private var showTitlePopover = false
    @State private var draftTitleZH: String = ""
    @State private var draftTitleEN: String = ""

    @State private var showCategoryPopover = false
    @State private var showSubtagPopover = false
    @State private var draftSubtag: String = ""

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
        df.dateFormat = "yyyy-MM-dd"
        return df
    }()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                CoverPreview(fileName: item.coverFileName) { artwork in
                    heroHeader(artwork)
                }
                statusSwitcherSection.padding(.horizontal, 20)
                ratingSection.padding(.horizontal, 20)
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
                    colors: [
                        Color.clear,
                        Color(nsColor: .windowBackgroundColor).opacity(0.75),
                        Color(nsColor: .windowBackgroundColor)
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
                        .shadow(color: .black.opacity(0.30), radius: 12, x: 0, y: 6)

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
                            .background(Color.black.opacity(0.65), in: Circle())
                            .overlay(
                                Circle()
                                    .strokeBorder(Color.white.opacity(0.25), lineWidth: 0.7)
                            )
                            .padding(7)
                            .transition(.opacity)
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
                    }
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isPosterHovered)
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .onTapGesture(perform: onReplaceCover)
                .onHover { isPosterHovered = $0 }
                .help(lang.tr("点击更换封面，或直接拖入图片", "Click to change cover, or drop an image here"))
                .onDrop(of: [.fileURL, .image, .url], isTargeted: $isDropTargeted) { providers in
                    CoverManager.shared.readDroppedImage(from: providers) { source in
                        if let source { store.importCover(source, for: item.id) }
                    }
                }

                VStack(spacing: 8) {
                    // Clickable Title & Subtitle (inline popover rename)
                    Button {
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
                    .padding(.horizontal, 12)
                    .onHover { isTitleHovered = $0 }
                    .help(lang.tr("点击修改中英文名称", "Click to edit titles"))
                    .popover(isPresented: $showTitlePopover, arrowEdge: .bottom) {
                        titleEditorPopover
                    }

                    // Clickable Category & Subtag Pills
                    HStack(spacing: 6) {
                        Button {
                            showCategoryPopover = true
                        } label: {
                            Label(item.category.title(in: lang), systemImage: item.category.systemImage)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(item.category.accentColor)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 3.5)
                                .background(
                                    item.category.accentColor.opacity(isCategoryHovered ? 0.22 : 0.14),
                                    in: Capsule()
                                )
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .onHover { isCategoryHovered = $0 }
                        .help(lang.tr("点击切换分类", "Click to change category"))
                        .popover(isPresented: $showCategoryPopover, arrowEdge: .bottom) {
                            categoryPickerPopover
                        }

                        Button {
                            draftSubtag = item.subtag
                            showSubtagPopover = true
                        } label: {
                            Group {
                                if !item.subtag.isEmpty {
                                    let shownTag = MediaCategory.localizedSubtag(item.subtag, in: lang)
                                    let prefix = item.category.subtagShortLabel(in: lang)
                                    Text(lang == .zh ? "\(prefix)：\(shownTag)" : "\(prefix): \(shownTag)")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.secondary)
                                } else {
                                    Label(lang.tr("标签", "Tag"), systemImage: "plus")
                                        .font(.system(size: 10.5, weight: .medium))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3.5)
                            .background(
                                Color.primary.opacity(isSubtagHovered ? 0.12 : (item.subtag.isEmpty ? 0.045 : 0.08)),
                                in: Capsule()
                            )
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .onHover { isSubtagHovered = $0 }
                        .help(lang.tr("点击设置标签", "Click to edit tag"))
                        .popover(isPresented: $showSubtagPopover, arrowEdge: .bottom) {
                            subtagEditorPopover
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 24)

            ShelfIconButton(
                systemName: "xmark",
                size: 28,
                iconSize: 11,
                helpText: lang.tr("收起详情栏 (Esc)", "Hide Details (Esc)"),
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
        VStack(alignment: .leading, spacing: 4) {
            ForEach(MediaCategory.allCases) { cat in
                let selected = (item.category == cat)
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
                            .fill(selected ? Color.accentColor : Color.clear)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .frame(width: 156)
    }

    private var subtagEditorPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(item.category.subtagFieldTitle(in: lang))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 62), spacing: 6)],
                alignment: .leading,
                spacing: 6
            ) {
                ForEach(item.category.presetTags, id: \.self) { tag in
                    ShelfChipButton(
                        title: MediaCategory.localizedSubtag(tag, in: lang),
                        isSelected: draftSubtag == tag
                    ) {
                        draftSubtag = (draftSubtag == tag) ? "" : tag
                        commitSubtagEdit()
                        showSubtagPopover = false
                    }
                }
            }

            HStack(spacing: 6) {
                TextField(lang.tr("自定义标签…", "Custom tag…"), text: $draftSubtag)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .font(.system(size: 12))
                    .onSubmit {
                        commitSubtagEdit()
                        showSubtagPopover = false
                    }

                if !draftSubtag.isEmpty {
                    Button(lang.tr("清除", "Clear")) {
                        draftSubtag = ""
                        commitSubtagEdit()
                        showSubtagPopover = false
                    }
                    .buttonStyle(
                        ShelfButtonStyle(
                            variant: .subtle,
                            horizontalPadding: 7,
                            verticalPadding: 4,
                            cornerRadius: 5
                        )
                    )
                    .font(.system(size: 11))
                }
            }
        }
        .padding(12)
        .frame(width: 244)
        .onDisappear {
            commitSubtagEdit()
        }
    }

    private func commitTitleEdit() {
        let cleanZH = draftTitleZH.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanEN = draftTitleEN.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanZH.isEmpty || !cleanEN.isEmpty else { return }
        let finalZH = cleanZH.isEmpty ? cleanEN : cleanZH
        guard finalZH != item.title || cleanEN != item.titleEN else { return }

        var updated = item
        updated.title = finalZH
        updated.titleEN = cleanEN
        updated.isSample = false
        store.updateItem(updated, originalCoverFileName: item.coverFileName)
    }

    private func applyCategoryChange(_ newCategory: MediaCategory) {
        guard newCategory != item.category else { return }
        var updated = item
        updated.category = newCategory
        let otherPresets = MediaCategory.allCases
            .filter { $0 != newCategory }
            .flatMap(\.presetTags)
        if otherPresets.contains(updated.subtag) && !newCategory.presetTags.contains(updated.subtag) {
            updated.subtag = ""
        }
        updated.isSample = false
        store.updateItem(updated, originalCoverFileName: item.coverFileName)
    }

    private func commitSubtagEdit() {
        let trimmed = draftSubtag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != item.subtag else { return }
        var updated = item
        updated.subtag = trimmed
        updated.isSample = false
        store.updateItem(updated, originalCoverFileName: item.coverFileName)
    }

    // MARK: - Status, Rating, Notes & Quiet Footer

    private var statusSwitcherSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(lang.tr("状态", "Status"))
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 6),
                    GridItem(.flexible(), spacing: 6)
                ],
                spacing: 6
            ) {
                ForEach(TrackingStatus.filterOrder) { st in
                    let isSelected = item.status == st
                    Button {
                        store.updateStatus(for: item.id, to: st)
                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(isSelected ? Color.white : st.tintColor)
                                .frame(width: 6.5, height: 6.5)
                            Text(item.category.statusLabel(for: st, in: lang))
                                .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(
                        ShelfButtonStyle(
                            variant: isSelected ? .primary : .secondary,
                            horizontalPadding: 10,
                            verticalPadding: 7,
                            cornerRadius: 8,
                            fullWidth: true
                        )
                    )
                }
            }
        }
    }

    private var ratingSection: some View {
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
                starSize: 16,
                spacing: 5,
                interactive: true
            )

            if item.rating > 0 {
                Text(lang == .zh ? "\(item.rating) 星" : "\(item.rating)★")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .trailing)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8)
        )
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

            ZStack(alignment: .topLeading) {
                if draftNotes.isEmpty {
                    Text(lang.tr("写点评价或备注…", "Write notes or thoughts…"))
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }

                TextEditor(text: $draftNotes)
                    .font(.system(size: 13))
                    .lineSpacing(4)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 8)
                    .frame(minHeight: 145)
                    .onChange(of: draftNotes) { _, newValue in
                        store.updateNotes(for: item.id, notes: newValue)
                    }
            }
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.8)
            )
        }
    }

    private var metadataFooter: some View {
        let createdStr = Self.dateFormatter.string(from: item.createdAt)
        let updatedStr = Self.dateFormatter.string(from: item.updatedAt)

        return HStack(spacing: 8) {
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
            .font(.system(size: 11.5))
            .foregroundStyle(.tertiary)
            .lineLimit(1)

            Spacer(minLength: 4)

            Button {
                showDeleteConfirm = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isDeleteHovered ? Color(red: 0.95, green: 0.34, blue: 0.34) : Color.secondary.opacity(0.75))
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(isDeleteHovered ? Color.red.opacity(0.13) : Color.clear)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { isDeleteHovered = $0 }
            .help(lang.tr("删除该作品", "Delete Item"))
        }
        .padding(.top, 2)
    }
}
