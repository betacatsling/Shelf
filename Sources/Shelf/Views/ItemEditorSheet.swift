import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ItemEditorSheet: View {
    let store: LibraryStore
    let existingItem: MediaItem?
    let defaultCategory: MediaCategory
    let defaultStatus: TrackingStatus
    let defaultTags: [String]
    let language: AppLanguage
    let onSave: (MediaItem) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var title: String = ""
    @State private var titleEN: String = ""
    @State private var category: MediaCategory = .game
    @State private var status: TrackingStatus = .active
    @State private var selectedTags: [String] = []
    @State private var rating: Int = 0
    @State private var hasStartedAt: Bool = false
    @State private var startedAtDate: Date = Date()
    @State private var hasFinishedAt: Bool = false
    @State private var finishedAtDate: Date = Date()
    @State private var notes: String = ""
    @State private var paletteSeed: Int = Int.random(in: 0..<1000)
    @State private var coverController = CoverImportController()
    @State private var showCoverPickerSheet = false
    @State private var isPosterHovered = false
    @FocusState private var focusedField: FocusField?

    private enum FocusField {
        case zhTitle
        case enTitle
    }

    init(
        store: LibraryStore,
        existingItem: MediaItem? = nil,
        defaultCategory: MediaCategory = .game,
        defaultStatus: TrackingStatus = .active,
        defaultTags: [String] = [],
        language: AppLanguage = .zh,
        onSave: @escaping (MediaItem) -> Void
    ) {
        self.store = store
        self.existingItem = existingItem
        self.defaultCategory = defaultCategory
        self.defaultStatus = defaultStatus
        self.defaultTags = defaultTags
        self.language = language
        self.onSave = onSave
    }

    private var hasValidTitle: Bool {
        !title.trimmed.isEmpty || !titleEN.trimmed.isEmpty
    }

    private var previewDisplayTitle: String {
        let zh = title.trimmed
        let en = titleEN.trimmed
        if language == .zh {
            return !zh.isEmpty ? zh : (!en.isEmpty ? en : "海报预览")
        }
        return !en.isEmpty ? en : (!zh.isEmpty ? zh : "Poster Preview")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(existingItem == nil ? language.tr("添加作品", "Add Item") : language.tr("编辑作品", "Edit Item"))
                    .font(.system(size: 16, weight: .bold))
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 14)

            ShelfHairline()

            HStack(alignment: .top, spacing: 24) {
                posterColumn.frame(width: 184)
                formColumn.frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)

            ShelfHairline()

            SheetFooterBar(
                errorMessage: coverController.errorMessage,
                cancelTitle: language.tr("取消", "Cancel"),
                confirmTitle: existingItem == nil ? language.tr("添加", "Add") : language.tr("保存", "Save"),
                confirmDisabled: !hasValidTitle || coverController.isLoading,
                horizontalPadding: 24,
                verticalPadding: 14,
                onCancel: { dismiss() },
                onConfirm: commitSave
            )
        }
        .frame(width: 690)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor))
        .onDisappear {
            coverController.tearDownAndCleanupUncommitted()
        }
        .onAppear {
            if let item = existingItem {
                title = item.title
                titleEN = item.titleEN
                category = item.category
                status = item.status
                selectedTags = item.tags
                rating = item.rating
                hasStartedAt = item.startedAt != nil
                startedAtDate = item.startedAt ?? item.finishedAt ?? Date()
                hasFinishedAt = item.finishedAt != nil
                finishedAtDate = item.finishedAt ?? item.startedAt ?? Date()
                notes = item.notes
                coverController.resetInitialCover(item.coverFileName)
                paletteSeed = item.paletteSeed
            } else {
                category = defaultCategory
                status = defaultStatus
                selectedTags = MediaCategory.normalizeTags(defaultTags)
                coverController.resetInitialCover(nil)
            }
            focusedField = (language == .en) ? .enTitle : .zhTitle
        }
        .sheet(isPresented: $showCoverPickerSheet) {
            let zh = title.trimmed
            let en = titleEN.trimmed
            let queryTitle = language == .en ? (en.isEmpty ? zh : en) : (zh.isEmpty ? en : zh)
            CoverPickerSheet(
                itemTitle: queryTitle,
                category: category,
                subtag: selectedTags.first ?? "",
                initialCoverFileName: coverController.coverFileName,
                paletteSeed: paletteSeed,
                language: language
            ) { chosenCover in
                if let chosenCover, chosenCover != coverController.coverFileName {
                    coverController.stageTemporaryCover(chosenCover)
                } else if chosenCover == nil {
                    coverController.coverFileName = nil
                }
            }
        }
    }

    // MARK: - Left Poster Column

    private var posterColumn: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                CoverDropPreviewView(
                    coverFileName: coverController.coverFileName,
                    title: previewDisplayTitle,
                    category: category,
                    subtag: selectedTags.first ?? "",
                    paletteSeed: paletteSeed,
                    language: language,
                    width: 164,
                    height: 246,
                    isDropTargeted: coverController.isDropTargeted,
                    isLoading: coverController.isLoading,
                    dropPrompt: language.tr("松开设为封面", "Drop to Set Cover")
                )

                if isPosterHovered && !coverController.isDropTargeted && !coverController.isLoading {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(.ultraThinMaterial, in: Circle())
                        .background(Color.black.opacity(0.45), in: Circle())
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.28), lineWidth: 0.7))
                        .padding(8)
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            .scaleEffect(!reduceMotion && isPosterHovered ? 1.02 : 1.0)
            .animation(reduceMotion ? nil : ShelfMotion.micro, value: isPosterHovered)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onTapGesture {
                coverController.errorMessage = nil
                coverController.cancelImport()
                showCoverPickerSheet = true
            }
            .onHover { isPosterHovered = $0 }
            .help(language.tr("点击在线搜索封面，或拖入本地/网页图片", "Click to search covers, or drop an image here"))
            .onDrop(of: [.fileURL, .image, .url], isTargeted: $coverController.isDropTargeted) { providers in
                coverController.handleDrop(providers: providers, language: language)
            }

            Button {
                coverController.errorMessage = nil
                coverController.cancelImport()
                showCoverPickerSheet = true
            } label: {
                Label(
                    language.tr("搜索封面…", "Search Cover…"),
                    systemImage: "magnifyingglass"
                )
                .font(.system(size: 11.5, weight: .semibold))
            }
            .buttonStyle(
                ShelfButtonStyle(
                    variant: .secondary,
                    horizontalPadding: 8,
                    verticalPadding: 6,
                    cornerRadius: 7,
                    fullWidth: true
                )
            )

            HStack(spacing: 6) {
                Button {
                    coverController.chooseLocalImage(language: language)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                        Text(language.tr("本地", "Local")).lineLimit(1)
                    }
                    .font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(
                    ShelfButtonStyle(
                        variant: .secondary,
                        horizontalPadding: 6,
                        verticalPadding: 6,
                        cornerRadius: 7,
                        fullWidth: true
                    )
                )

                Button {
                    coverController.pasteFromClipboard(language: language)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.clipboard")
                        Text(language.tr("粘贴", "Paste")).lineLimit(1)
                    }
                    .font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(
                    ShelfButtonStyle(
                        variant: .secondary,
                        horizontalPadding: 6,
                        verticalPadding: 6,
                        cornerRadius: 7,
                        fullWidth: true
                    )
                )
                .help(language.tr("粘贴剪贴板图片、截图或图片链接", "Paste image, screenshot, or image URL from clipboard"))
            }

            if coverController.coverFileName != nil {
                Button {
                    coverController.resetToDefaultCover()
                } label: {
                    Label(language.tr("恢复默认封面", "Reset Cover"), systemImage: "arrow.uturn.backward")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(ShelfButtonStyle(variant: .subtle, horizontalPadding: 10, verticalPadding: 4, cornerRadius: 6))
            } else {
                Button {
                    paletteSeed = Int.random(in: 0..<1000)
                } label: {
                    Label(language.tr("换个配色", "Shuffle Palette"), systemImage: "paintpalette")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(ShelfButtonStyle(variant: .subtle, horizontalPadding: 10, verticalPadding: 4, cornerRadius: 6))
            }
        }
    }

    // MARK: - Right Form Column

    private var formColumn: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(language.tr("中文名称（无官中可填原名）", "Chinese Title"))
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.secondary)

                    TextField(language.tr("例如：沉星之序 / 诡秘之主", "e.g. 沉星之序 / 诡秘之主"), text: $title)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13.5))
                        .focused($focusedField, equals: .zhTitle)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(language.tr("英文名称（无官翻可留空）", "English Title (Optional)"))
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.secondary)

                    TextField("e.g. Order of the Sinking Star", text: $titleEN)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13.5))
                        .focused($focusedField, equals: .enTitle)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(language.tr("所属类别", "Category"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                ShelfSegmentedControl(
                    segments: MediaCategory.allCases.map { cat in
                        .init(value: cat, title: cat.title(in: language), icon: cat.systemImage)
                    },
                    selection: $category,
                    verticalPadding: 6
                )
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(language.tr("当前状态", "Status"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                ShelfSegmentedControl(
                    segments: TrackingStatus.filterOrder.map { st in
                        .init(
                            value: st,
                            title: category.statusLabel(for: st, in: language),
                            dotColor: st.tintColor
                        )
                    },
                    selection: $status,
                    verticalPadding: 6
                )
            }

            InlineTagField(
                store: store,
                selectedTags: $selectedTags,
                language: language
            )

            HStack {
                Text(language.tr("个人评分", "Rating"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                StarRatingView(rating: $rating, starSize: 17, spacing: 5, interactive: true)
                if rating > 0 {
                    Button(language.tr("清除", "Clear")) { rating = 0 }
                        .buttonStyle(ShelfButtonStyle(variant: .subtle, horizontalPadding: 6, verticalPadding: 3, cornerRadius: 5))
                        .font(.system(size: 11))
                        .padding(.leading, 4)
                }
            }

            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Toggle(language.tr("开始日期", "Start"), isOn: $hasStartedAt)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    if hasStartedAt {
                        DatePicker("", selection: $startedAtDate, displayedComponents: .date)
                            .labelsHidden()
                            .datePickerStyle(.field)
                            .controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 6) {
                    Toggle(language.tr("结束日期", "Finish"), isOn: $hasFinishedAt)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    if hasFinishedAt {
                        DatePicker("", selection: $finishedAtDate, displayedComponents: .date)
                            .labelsHidden()
                            .datePickerStyle(.field)
                            .controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .animation(reduceMotion ? nil : ShelfMotion.control, value: hasStartedAt)
            .animation(reduceMotion ? nil : ShelfMotion.control, value: hasFinishedAt)

            VStack(alignment: .leading, spacing: 5) {
                Text(language.tr("随笔与感想（可选）", "Notes & Thoughts (Optional)"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                ShelfNotesEditor(
                    text: $notes,
                    placeholder: language.tr("写点简短评价、期待理由或观后感…", "Write a short review or notes…"),
                    fontSize: 12.5,
                    minHeight: 74,
                    fillOpacity: 0.05,
                    borderOpacity: 0.12,
                    cornerRadius: 8
                )
                .frame(height: 74)
            }
        }
    }

    private func commitSave() {
        let cleanZH = title.trimmed
        let cleanEN = titleEN.trimmed
        guard !cleanZH.isEmpty || !cleanEN.isEmpty else { return }

        let finalZH = cleanZH.isEmpty ? cleanEN : cleanZH
        let chosenCover = coverController.commitAndCleanupUnused()
        let cal = TimelineLayoutModel.gregorianCalendar
        var normalizedStart = hasStartedAt ? cal.startOfDay(for: startedAtDate) : nil
        var normalizedFinish = hasFinishedAt ? cal.startOfDay(for: finishedAtDate) : nil
        if let s = normalizedStart, let f = normalizedFinish, s > f {
            normalizedStart = f
            normalizedFinish = s
        }

        var result: MediaItem
        if var existing = existingItem {
            existing.title = finalZH
            existing.titleEN = cleanEN
            existing.category = category
            existing.status = status
            existing.tags = MediaCategory.normalizeTags(selectedTags)
            existing.rating = rating
            existing.notes = notes
            existing.coverFileName = chosenCover
            existing.paletteSeed = paletteSeed
            existing.startedAt = normalizedStart
            existing.finishedAt = normalizedFinish
            existing.isSample = false
            result = existing
        } else {
            result = MediaItem(
                title: finalZH,
                titleEN: cleanEN,
                category: category,
                status: status,
                tags: selectedTags,
                rating: rating,
                notes: notes,
                coverFileName: chosenCover,
                paletteSeed: paletteSeed,
                startedAt: normalizedStart,
                finishedAt: normalizedFinish,
                isSample: false
            )
        }

        onSave(result)
        dismiss()
    }
}
