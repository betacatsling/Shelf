import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ItemEditorSheet: View {
    let existingItem: MediaItem?
    let defaultCategory: MediaCategory
    let defaultStatus: TrackingStatus
    let language: AppLanguage
    let onSave: (MediaItem) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var title: String = ""
    @State private var titleEN: String = ""
    @State private var category: MediaCategory = .game
    @State private var status: TrackingStatus = .active
    @State private var subtag: String = ""
    @State private var rating: Int = 0
    @State private var notes: String = ""
    @State private var coverFileName: String? = nil
    @State private var paletteSeed: Int = Int.random(in: 0..<1000)

    @State private var isLoadingCover = false
    @State private var coverImportTask: Task<Void, Never>?
    @State private var dropID: UUID?
    @State private var coverErrorMessage: String? = nil
    @State private var isDropTargeted = false
    @State private var showCoverPickerSheet = false

    @State private var temporaryCoverFiles: [String] = []
    @FocusState private var focusedField: FocusField?

    private enum FocusField {
        case zhTitle
        case enTitle
    }

    init(
        existingItem: MediaItem? = nil,
        defaultCategory: MediaCategory = .game,
        defaultStatus: TrackingStatus = .active,
        language: AppLanguage = .zh,
        onSave: @escaping (MediaItem) -> Void
    ) {
        self.existingItem = existingItem
        self.defaultCategory = defaultCategory
        self.defaultStatus = defaultStatus
        self.language = language
        self.onSave = onSave
    }

    private var hasValidTitle: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !titleEN.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var previewDisplayTitle: String {
        let zh = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let en = titleEN.trimmingCharacters(in: .whitespacesAndNewlines)
        if language == .zh {
            return !zh.isEmpty ? zh : (!en.isEmpty ? en : "海报预览")
        } else {
            return !en.isEmpty ? en : (!zh.isEmpty ? zh : "Poster Preview")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(
                    existingItem == nil
                        ? language.tr("添加作品", "Add Item")
                        : language.tr("编辑作品", "Edit Item")
                )
                .font(.system(size: 16, weight: .bold))
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 14)

            Divider()

            HStack(alignment: .top, spacing: 24) {
                posterColumn
                    .frame(width: 192)

                formColumn
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)

            Divider()

            HStack(spacing: 10) {
                if let coverErrorMessage {
                    Label(coverErrorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
                Spacer()

                Button(language.tr("取消", "Cancel")) {
                    dismiss()
                }
                .buttonStyle(
                    ShelfButtonStyle(
                        variant: .secondary,
                        horizontalPadding: 18,
                        verticalPadding: 7,
                        cornerRadius: 8
                    )
                )
                .font(.system(size: 13, weight: .medium))
                .keyboardShortcut(.cancelAction)

                Button(
                    existingItem == nil
                        ? language.tr("添加", "Add")
                        : language.tr("保存", "Save")
                ) {
                    commitSave()
                }
                .buttonStyle(
                    ShelfButtonStyle(
                        variant: .primary,
                        horizontalPadding: 20,
                        verticalPadding: 7,
                        cornerRadius: 8
                    )
                )
                .font(.system(size: 13, weight: .semibold))
                .disabled(!hasValidTitle || isLoadingCover)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(width: 690)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor))
        .onDisappear {
            coverImportTask?.cancel()
            dropID = nil
            cleanupUncommittedCovers()
        }
        .onAppear {
            if let item = existingItem {
                title = item.title
                titleEN = item.titleEN
                category = item.category
                status = item.status
                subtag = item.subtag
                rating = item.rating
                notes = item.notes
                coverFileName = item.coverFileName
                paletteSeed = item.paletteSeed
            } else {
                category = defaultCategory
                status = defaultStatus
            }
            focusedField = (language == .en) ? .enTitle : .zhTitle
        }
        .sheet(isPresented: $showCoverPickerSheet) {
            let queryTitle = {
                let zh = title.trimmingCharacters(in: .whitespacesAndNewlines)
                let en = titleEN.trimmingCharacters(in: .whitespacesAndNewlines)
                return language == .en ? (en.isEmpty ? zh : en) : (zh.isEmpty ? en : zh)
            }()
            CoverPickerSheet(
                itemTitle: queryTitle,
                category: category,
                subtag: subtag,
                initialCoverFileName: coverFileName,
                paletteSeed: paletteSeed,
                language: language
            ) { chosenCover in
                if let chosenCover, chosenCover != coverFileName {
                    assignNewTemporaryCover(chosenCover)
                } else if chosenCover == nil {
                    coverFileName = nil
                }
            }
        }
    }

    // MARK: - Left Poster Column

    private var posterColumn: some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.black)
                    .frame(width: 164, height: 246)
                    .shadow(color: .black.opacity(0.28), radius: 12, x: 0, y: 6)

                CoverPreview(fileName: coverFileName) { artwork in
                    CoverArtworkView(
                        title: previewDisplayTitle,
                        category: category,
                        subtag: subtag,
                        image: artwork?.image,
                        paletteSeed: paletteSeed,
                        language: language,
                        cornerRadius: 12,
                        isHovered: isDropTargeted
                    )
                }
                .frame(width: 164, height: 246)

                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.accentColor.opacity(0.32))
                        .frame(width: 164, height: 246)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        )
                        .overlay(
                            Text(language.tr("松开设为封面", "Drop to Set Cover"))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.black.opacity(0.72), in: Capsule())
                        )
                }

                if isLoadingCover {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.black.opacity(0.5))
                        .frame(width: 164, height: 246)
                        .overlay(
                            ProgressView()
                                .controlSize(.regular)
                                .tint(.white)
                        )
                }
            }
            .onDrop(of: [.fileURL, .image, .url], isTargeted: $isDropTargeted) { providers in
                let id = UUID()
                coverErrorMessage = nil
                dropID = id
                let accepted = CoverManager.shared.readDroppedImage(from: providers) { source in
                    guard dropID == id else { return }
                    dropID = nil
                    if let source {
                        importCover(source)
                    } else {
                        isLoadingCover = false
                        coverErrorMessage = CoverError.invalidImageData.message(in: language)
                    }
                }
                if accepted {
                    coverImportTask?.cancel()
                    isLoadingCover = true
                } else {
                    dropID = nil
                }
                return accepted
            }

            Button {
                coverErrorMessage = nil
                coverImportTask?.cancel()
                dropID = nil
                isLoadingCover = false
                showCoverPickerSheet = true
            } label: {
                Label(
                    language.tr("在线搜索 / 更换封面…", "Search / Change Cover…"),
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
                    coverErrorMessage = nil
                    if let url = CoverManager.shared.chooseLocalImagePanel(lang: language) {
                        importCover(.file(url))
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                        Text(language.tr("本地图片", "Local"))
                            .lineLimit(1)
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
                    handlePasteCover()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.clipboard")
                        Text(language.tr("粘贴图片", "Paste"))
                            .lineLimit(1)
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

            if coverFileName != nil {
                Button {
                    coverFileName = nil
                } label: {
                    Label(language.tr("恢复默认封面", "Reset Default Cover"), systemImage: "arrow.uturn.backward")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(
                    ShelfButtonStyle(
                        variant: .subtle,
                        horizontalPadding: 10,
                        verticalPadding: 4,
                        cornerRadius: 6
                    )
                )
            } else {
                Button {
                    paletteSeed = Int.random(in: 0..<1000)
                } label: {
                    Label(language.tr("换个封面配色", "Shuffle Palette"), systemImage: "paintpalette")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(
                    ShelfButtonStyle(
                        variant: .subtle,
                        horizontalPadding: 10,
                        verticalPadding: 4,
                        cornerRadius: 6
                    )
                )
            }
        }
    }

    // MARK: - Right Form Column

    private var formColumn: some View {
        VStack(alignment: .leading, spacing: 13) {
            // 1. Bilingual Titles
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

            // 2. Category
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
                .onChange(of: category) { _, newCategory in
                    let otherPresets = MediaCategory.allCases
                        .filter { $0 != newCategory }
                        .flatMap(\.presetTags)
                    if otherPresets.contains(subtag) && !newCategory.presetTags.contains(subtag) {
                        subtag = ""
                    }
                }
            }

            // 3. Status
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

            // 4. Optional Subtag
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(category.subtagFieldTitle(in: language))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    TextField(language.tr("自定义", "Custom"), text: $subtag)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .frame(width: 128)
                }

                HStack(spacing: 6) {
                    ForEach(category.presetTags, id: \.self) { tag in
                        ShelfChipButton(
                            title: MediaCategory.localizedSubtag(tag, in: language),
                            isSelected: subtag == tag
                        ) {
                            subtag = (subtag == tag) ? "" : tag
                        }
                    }
                }
            }

            // 5. Rating
            HStack {
                Text(language.tr("个人评分", "Rating"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                StarRatingView(rating: $rating, starSize: 17, spacing: 5, interactive: true)
                if rating > 0 {
                    Button(language.tr("清除", "Clear")) { rating = 0 }
                        .buttonStyle(
                            ShelfButtonStyle(
                                variant: .subtle,
                                horizontalPadding: 6,
                                verticalPadding: 3,
                                cornerRadius: 5
                            )
                        )
                        .font(.system(size: 11))
                        .padding(.leading, 4)
                }
            }

            // 6. Notes
            VStack(alignment: .leading, spacing: 5) {
                Text(language.tr("随笔与感想（可选）", "Notes & Thoughts (Optional)"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                ZStack(alignment: .topLeading) {
                    if notes.isEmpty {
                        Text(language.tr("写点简短评价、期待理由或观后感…", "Write a short review or notes…"))
                            .font(.system(size: 12.5))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 9)
                            .allowsHitTesting(false)
                    }

                    TextEditor(text: $notes)
                        .font(.system(size: 12.5))
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 5)
                        .frame(height: 74)
                }
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.8)
                )
            }
        }
    }

    // MARK: - Helpers

    private func assignNewTemporaryCover(_ fileName: String) {
        temporaryCoverFiles.append(fileName)
        coverFileName = fileName
    }

    private func handlePasteCover() {
        if let source = CoverManager.shared.inspectPasteboard() {
            importCover(source)
        } else {
            coverErrorMessage = language.tr("剪贴板中没有检测到图片或图片链接", "No image or image URL in clipboard")
        }
    }

    private func importCover(_ source: CoverSource) {
        dropID = nil
        coverImportTask?.cancel()
        coverErrorMessage = nil
        isLoadingCover = true
        coverImportTask = Task {
            do {
                let saved = try await CoverManager.shared.saveCover(from: source)
                assignNewTemporaryCover(saved)
            } catch {
                if Task.isCancelled { return }
                coverErrorMessage = error.localizedDescription
            }
            isLoadingCover = false
        }
    }

    private func cleanupUncommittedCovers() {
        for temp in temporaryCoverFiles where temp != existingItem?.coverFileName {
            CoverManager.shared.removeCover(fileName: temp)
        }
        temporaryCoverFiles.removeAll()
    }

    private func commitSave() {
        let cleanZH = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanEN = titleEN.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanZH.isEmpty || !cleanEN.isEmpty else { return }

        // Ensure primary `title` is always populated so JSON remains clean even if only English was entered
        let finalZH = cleanZH.isEmpty ? cleanEN : cleanZH
        let finalEN = cleanEN

        for temp in temporaryCoverFiles where temp != coverFileName && temp != existingItem?.coverFileName {
            CoverManager.shared.removeCover(fileName: temp)
        }
        var result: MediaItem
        if var existing = existingItem {
            existing.title = finalZH
            existing.titleEN = finalEN
            existing.category = category
            existing.status = status
            existing.subtag = subtag.trimmingCharacters(in: .whitespacesAndNewlines)
            existing.rating = rating
            existing.notes = notes
            existing.coverFileName = coverFileName
            existing.paletteSeed = paletteSeed
            existing.isSample = false
            result = existing
        } else {
            result = MediaItem(
                title: finalZH,
                titleEN: finalEN,
                category: category,
                status: status,
                subtag: subtag.trimmingCharacters(in: .whitespacesAndNewlines),
                rating: rating,
                notes: notes,
                coverFileName: coverFileName,
                paletteSeed: paletteSeed,
                isSample: false
            )
        }

        temporaryCoverFiles.removeAll()
        onSave(result)
        dismiss()
    }
}
