import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ItemEditorSheet: View {
    let existingItem: MediaItem?
    let defaultCategory: MediaCategory
    let defaultStatus: TrackingStatus
    let onSave: (MediaItem) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var title: String = ""
    @State private var category: MediaCategory = .game
    @State private var status: TrackingStatus = .active
    @State private var subtag: String = ""
    @State private var rating: Int = 0
    @State private var notes: String = ""
    @State private var coverFileName: String? = nil
    @State private var paletteSeed: Int = Int.random(in: 0..<1000)

    @State private var remoteURLInput: String = ""
    @State private var isDownloadingCover = false
    @State private var coverErrorMessage: String? = nil
    @State private var isDropTargeted = false
    @State private var showCoverPickerSheet = false

    @State private var temporaryCoverFiles: [String] = []
    @FocusState private var isTitleFocused: Bool

    init(
        existingItem: MediaItem? = nil,
        defaultCategory: MediaCategory = .game,
        defaultStatus: TrackingStatus = .active,
        onSave: @escaping (MediaItem) -> Void
    ) {
        self.existingItem = existingItem
        self.defaultCategory = defaultCategory
        self.defaultStatus = defaultStatus
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            // Sheet Header
            HStack {
                Text(existingItem == nil ? "添加作品" : "编辑作品")
                    .font(.system(size: 16, weight: .bold))
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 14)

            Divider()

            // Main Two-Column Form
            HStack(alignment: .top, spacing: 24) {
                posterColumn
                    .frame(width: 192)

                formColumn
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)

            Divider()

            // Footer Actions
            HStack(spacing: 10) {
                if let coverErrorMessage {
                    Label(coverErrorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
                Spacer()

                Button("取消") {
                    cleanupUncommittedCovers()
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

                Button(existingItem == nil ? "添加" : "保存") {
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
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isDownloadingCover)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(width: 680)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if let item = existingItem {
                title = item.title
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
            isTitleFocused = true
        }
        .sheet(isPresented: $showCoverPickerSheet) {
            CoverPickerSheet(
                itemTitle: title,
                category: category,
                subtag: subtag,
                initialCoverFileName: coverFileName,
                paletteSeed: paletteSeed
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

                CoverArtworkView(
                    title: title.isEmpty ? "海报预览" : title,
                    category: category,
                    subtag: subtag,
                    coverFileName: coverFileName,
                    paletteSeed: paletteSeed,
                    cornerRadius: 12,
                    isHovered: isDropTargeted,
                    useThumbnail: false
                )
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
                            Text("松开设为封面")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.black.opacity(0.72), in: Capsule())
                        )
                }

                if isDownloadingCover {
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
                coverErrorMessage = nil
                return CoverManager.shared.extractDroppedCover(from: providers) { result in
                    switch result {
                    case .success(let saved):
                        assignNewTemporaryCover(saved)
                    case .failure(let err):
                        coverErrorMessage = err.localizedDescription
                    }
                }
            }

            Button {
                coverErrorMessage = nil
                showCoverPickerSheet = true
            } label: {
                Label("在线搜索 / 更换封面…", systemImage: "magnifyingglass")
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

            // Cover Action Buttons (crisp visible borders & full hit target)
            HStack(spacing: 6) {
                Button {
                    coverErrorMessage = nil
                    if let url = CoverManager.shared.chooseLocalImagePanel(),
                       let saved = CoverManager.shared.saveImageFromFileURL(url) {
                        assignNewTemporaryCover(saved)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                        Text("本地图片")
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
                        Text("粘贴图片")
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
                .help("粘贴剪贴板中的截图、复制的网页图片或图片链接")
            }

            // URL Input
            HStack(spacing: 5) {
                TextField("粘贴图片网络链接…", text: $remoteURLInput)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .font(.system(size: 11))
                    .onSubmit {
                        fetchRemoteCover()
                    }

                if !remoteURLInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button("加载") {
                        fetchRemoteCover()
                    }
                    .buttonStyle(
                        ShelfButtonStyle(
                            variant: .primary,
                            horizontalPadding: 9,
                            verticalPadding: 4,
                            cornerRadius: 6
                        )
                    )
                    .font(.system(size: 11, weight: .semibold))
                    .disabled(isDownloadingCover)
                }
            }

            if coverFileName != nil {
                Button {
                    coverFileName = nil
                } label: {
                    Label("恢复默认封面", systemImage: "arrow.uturn.backward")
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
                    Label("换个封面配色", systemImage: "paintpalette")
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
        VStack(alignment: .leading, spacing: 15) {
            // 1. Title
            VStack(alignment: .leading, spacing: 6) {
                Text("作品名称")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                TextField("例如：艾尔登法环 / 诡秘之主 / 进击的巨人", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 14))
                    .focused($isTitleFocused)
            }

            // 2. Category (Custom crisp segmented control!)
            VStack(alignment: .leading, spacing: 6) {
                Text("所属类别")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                ShelfSegmentedControl(
                    segments: MediaCategory.allCases.map { cat in
                        .init(value: cat, title: cat.title, icon: cat.systemImage)
                    },
                    selection: $category,
                    verticalPadding: 6
                )
            }

            // 3. Status (Custom crisp segmented control!)
            VStack(alignment: .leading, spacing: 6) {
                Text("当前状态")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                ShelfSegmentedControl(
                    segments: TrackingStatus.filterOrder.map { st in
                        .init(
                            value: st,
                            title: category.statusLabel(for: st),
                            dotColor: st.tintColor
                        )
                    },
                    selection: $status,
                    verticalPadding: 6
                )
            }

            // 4. Optional Subtag
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(category.subtagFieldTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    TextField("自定义", text: $subtag)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .frame(width: 128)
                }

                HStack(spacing: 6) {
                    ForEach(category.presetTags, id: \.self) { tag in
                        ShelfChipButton(title: tag, isSelected: subtag == tag) {
                            subtag = (subtag == tag) ? "" : tag
                        }
                    }
                }
            }

            // 5. Rating
            HStack {
                Text("个人评分")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                StarRatingView(rating: $rating, starSize: 17, spacing: 5, interactive: true)
                if rating > 0 {
                    Button("清除") { rating = 0 }
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
            VStack(alignment: .leading, spacing: 6) {
                Text("随笔与感想（可选）")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                ZStack(alignment: .topLeading) {
                    if notes.isEmpty {
                        Text("写点简短评价、期待理由或观后感…")
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
        coverErrorMessage = nil
        switch CoverManager.shared.inspectPasteboard() {
        case .image(let img):
            if let saved = CoverManager.shared.saveImage(img) {
                assignNewTemporaryCover(saved)
            }
        case .fileURL(let url):
            if let saved = CoverManager.shared.saveImageFromFileURL(url) {
                assignNewTemporaryCover(saved)
            } else {
                coverErrorMessage = "无法读取该本地图片"
            }
        case .remoteURL(let urlStr):
            remoteURLInput = urlStr
            fetchRemoteCover()
        case .empty:
            coverErrorMessage = "剪贴板中没有检测到图片或图片链接"
        }
    }

    private func fetchRemoteCover() {
        let urlStr = remoteURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !urlStr.isEmpty else { return }
        coverErrorMessage = nil
        isDownloadingCover = true

        Task {
            do {
                let saved = try await CoverManager.shared.downloadAndSaveImage(from: urlStr)
                assignNewTemporaryCover(saved)
                remoteURLInput = ""
            } catch {
                coverErrorMessage = error.localizedDescription
            }
            isDownloadingCover = false
        }
    }

    private func cleanupUncommittedCovers() {
        for temp in temporaryCoverFiles where temp != existingItem?.coverFileName {
            CoverManager.shared.removeCover(fileName: temp)
        }
    }

    private func commitSave() {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return }

        for temp in temporaryCoverFiles where temp != coverFileName && temp != existingItem?.coverFileName {
            CoverManager.shared.removeCover(fileName: temp)
        }
        if let oldCover = existingItem?.coverFileName, oldCover != coverFileName {
            CoverManager.shared.removeCover(fileName: oldCover)
        }

        var result: MediaItem
        if var existing = existingItem {
            existing.title = cleanTitle
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
                title: cleanTitle,
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

        onSave(result)
        dismiss()
    }
}
