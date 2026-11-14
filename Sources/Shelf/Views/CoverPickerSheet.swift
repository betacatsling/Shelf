import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CoverPickerSheet: View {
    let itemTitle: String
    let category: MediaCategory
    let subtag: String
    let initialCoverFileName: String?
    let paletteSeed: Int
    var language: AppLanguage = .zh
    let onCommitCover: (String?) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var previewCoverFileName: String?
    @State private var temporaryFiles: [String] = []

    @State private var searchQuery: String = ""
    @State private var searchAllCategories: Bool = false
    @State private var candidates: [CoverCandidate] = []
    @State private var isSearching: Bool = false
    @State private var hasSearchedOnce: Bool = false
    @State private var selectedCandidateID: String? = nil

    @State private var remoteLinkInput: String = ""
    @State private var isLoadingPreview: Bool = false
    @State private var statusMessage: String? = nil
    @State private var isDropTargeted: Bool = false

    @State private var activeSearchTask: Task<Void, Never>? = nil

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            HStack(alignment: .top, spacing: 0) {
                leftManualPanel
                    .frame(width: 236)

                Divider()

                rightOnlineSearchPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: 468)

            Divider()
            footerBar
        }
        .frame(width: 760)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            previewCoverFileName = initialCoverFileName
            let trimmed = itemTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            searchQuery = trimmed
            if !trimmed.isEmpty {
                triggerOnlineSearch()
            }
        }
        .onDisappear {
            activeSearchTask?.cancel()
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.accentColor)

            Text(language.tr("更换封面", "Change Cover"))
                .font(.system(size: 16, weight: .bold))

            if !itemTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(language == .zh ? "· 《\(itemTitle)》" : "· \(itemTitle)")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 15)
    }

    // MARK: - Left Column: Preview + Manual Local / Clipboard / Link

    private var leftManualPanel: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.black)
                    .frame(width: 156, height: 234)
                    .shadow(color: .black.opacity(0.28), radius: 12, x: 0, y: 6)

                CoverArtworkView(
                    title: itemTitle.isEmpty ? language.tr("封面预览", "Cover Preview") : itemTitle,
                    category: category,
                    subtag: subtag,
                    coverFileName: previewCoverFileName,
                    paletteSeed: paletteSeed,
                    language: language,
                    cornerRadius: 12,
                    isHovered: isDropTargeted,
                    useThumbnail: false
                )
                .frame(width: 156, height: 234)

                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.accentColor.opacity(0.32))
                        .frame(width: 156, height: 234)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        )
                        .overlay(
                            Text(language.tr("松开替换封面", "Drop to Replace"))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.black.opacity(0.75), in: Capsule())
                        )
                }

                if isLoadingPreview {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.black.opacity(0.52))
                        .frame(width: 156, height: 234)
                        .overlay(
                            VStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.regular)
                                    .tint(.white)
                                Text(language.tr("正在载入图片…", "Loading image…"))
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.9))
                            }
                        )
                }
            }
            .padding(.top, 4)

            VStack(spacing: 8) {
                Button {
                    statusMessage = nil
                    if let url = CoverManager.shared.chooseLocalImagePanel(lang: language) {
                        if let saved = CoverManager.shared.saveImageFromFileURL(url) {
                            selectedCandidateID = nil
                            stageTemporaryCover(saved)
                        } else {
                            statusMessage = language.tr("无法读取所选本地图片", "Cannot read selected image")
                        }
                    }
                } label: {
                    Label(language.tr("选择本地图片…", "Choose Local Image…"), systemImage: "folder")
                        .font(.system(size: 12.5, weight: .medium))
                }
                .buttonStyle(
                    ShelfButtonStyle(
                        variant: .secondary,
                        horizontalPadding: 12,
                        verticalPadding: 7,
                        cornerRadius: 8,
                        fullWidth: true
                    )
                )

                Button {
                    pasteFromClipboard()
                } label: {
                    Label(language.tr("从剪贴板粘贴", "Paste from Clipboard"), systemImage: "doc.on.clipboard")
                        .font(.system(size: 12.5, weight: .medium))
                }
                .buttonStyle(
                    ShelfButtonStyle(
                        variant: .secondary,
                        horizontalPadding: 12,
                        verticalPadding: 7,
                        cornerRadius: 8,
                        fullWidth: true
                    )
                )

                HStack(spacing: 6) {
                    TextField(language.tr("输入图片网络链接…", "Enter image URL…"), text: $remoteLinkInput)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .font(.system(size: 11.5))
                        .onSubmit {
                            loadFromLinkInput()
                        }

                    Button(language.tr("读取", "Load")) {
                        loadFromLinkInput()
                    }
                    .buttonStyle(
                        ShelfButtonStyle(
                            variant: .secondary,
                            horizontalPadding: 9,
                            verticalPadding: 4.5,
                            cornerRadius: 6
                        )
                    )
                    .font(.system(size: 11.5, weight: .medium))
                    .disabled(remoteLinkInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoadingPreview)
                }
                .padding(.top, 2)

                if previewCoverFileName != nil {
                    Button {
                        selectedCandidateID = nil
                        previewCoverFileName = nil
                        statusMessage = nil
                    } label: {
                        Label(language.tr("恢复默认封面", "Reset Default Cover"), systemImage: "arrow.uturn.backward")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .buttonStyle(
                        ShelfButtonStyle(
                            variant: .subtle,
                            horizontalPadding: 10,
                            verticalPadding: 5,
                            cornerRadius: 7,
                            fullWidth: true
                        )
                    )
                }
            }
            .padding(.horizontal, 18)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 16)
        .background(Color.primary.opacity(0.02))
        .onDrop(of: [.fileURL, .image, .url], isTargeted: $isDropTargeted) { providers in
            statusMessage = nil
            return CoverManager.shared.extractDroppedCover(from: providers) { result in
                switch result {
                case .success(let saved):
                    selectedCandidateID = nil
                    stageTemporaryCover(saved)
                case .failure(let err):
                    statusMessage = err.localizedDescription
                }
            }
        }
    }

    // MARK: - Right Column: Online Visual Poster Search

    private var rightOnlineSearchPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)

                    TextField(language.tr("输入作品名称搜索海报…", "Search posters by title…"), text: $searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .onSubmit {
                            triggerOnlineSearch()
                        }

                    if !searchQuery.isEmpty {
                        Button {
                            searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6.5)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.8)
                )

                ShelfSegmentedControl(
                    segments: [
                        .init(value: false, title: category.title(in: language)),
                        .init(value: true, title: language.tr("全部", "All"))
                    ],
                    selection: $searchAllCategories,
                    verticalPadding: 5
                )
                .fixedSize()
                .onChange(of: searchAllCategories) { _, _ in
                    if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        triggerOnlineSearch()
                    }
                }

                Button {
                    triggerOnlineSearch()
                } label: {
                    Text(language.tr("搜索", "Search"))
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .buttonStyle(
                    ShelfButtonStyle(
                        variant: .primary,
                        horizontalPadding: 14,
                        verticalPadding: 6.5,
                        cornerRadius: 8
                    )
                )
                .fixedSize()
                .disabled(searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSearching)
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)

            if isSearching && candidates.isEmpty {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.regular)
                    Text(language.tr("正在搜索匹配的高清竖版封面…", "Searching for vertical posters…"))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if candidates.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: hasSearchedOnce ? "photo.badge.magnifyingglass" : "sparkle.magnifyingglass")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(.secondary.opacity(0.7))

                    Text(
                        hasSearchedOnce
                            ? language.tr("未找到匹配的在线封面", "No Matching Covers Found")
                            : language.tr("输入作品名即可在线搜索封面", "Search Online Posters by Title")
                    )
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.85))

                    Text(
                        hasSearchedOnce
                            ? language.tr(
                                "可以尝试精简关键词（例如去掉副标题或版本号），或使用左侧本地选图、剪贴板粘贴。",
                                "Try a shorter keyword without subtitles, or choose a local image / paste from clipboard."
                            )
                            : language.tr(
                                "单击候选图可在左侧预览裁剪效果，双击可直接应用。",
                                "Single-click a poster to preview; double-click to apply immediately."
                            )
                    )
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 6) {
                    Text(language.tr("候选封面（\(candidates.count)）", "Candidates (\(candidates.count))"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    if isSearching {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    Spacer()
                }
                .padding(.horizontal, 18)

                ScrollView {
                    LazyVGrid(
                        columns: [
                            GridItem(.adaptive(minimum: 118, maximum: 148), spacing: 14)
                        ],
                        spacing: 16
                    ) {
                        ForEach(candidates) { candidate in
                            CoverCandidateCard(
                                candidate: candidate,
                                isSelected: selectedCandidateID == candidate.id,
                                language: language,
                                onSelect: {
                                    let clickCount = NSApp.currentEvent?.clickCount ?? 1
                                    selectCandidate(candidate, applyImmediately: clickCount >= 2)
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 18)
                }
            }
        }
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack(spacing: 10) {
            if let statusMessage {
                Label(statusMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }

            Spacer()

            Button(language.tr("取消", "Cancel")) {
                cleanupUncommittedFiles()
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

            Button(language.tr("保存封面", "Save Cover")) {
                commitSelection()
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
            .disabled(isLoadingPreview)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 13)
    }

    // MARK: - Actions

    private func stageTemporaryCover(_ savedFileName: String) {
        temporaryFiles.append(savedFileName)
        previewCoverFileName = savedFileName
    }

    private func triggerOnlineSearch() {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        activeSearchTask?.cancel()
        isSearching = true
        candidates = []
        statusMessage = nil

        let targetCategory: MediaCategory? = searchAllCategories ? nil : category
        let activeLang = language
        activeSearchTask = Task {
            await CoverSearchService.shared.searchCoversProgressively(
                query: trimmed,
                category: targetCategory,
                language: activeLang
            ) { partial in
                self.candidates = partial
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.hasSearchedOnce = true
                self.isSearching = false
            }
        }
    }

    private func selectCandidate(_ candidate: CoverCandidate, applyImmediately: Bool) {
        selectedCandidateID = candidate.id
        statusMessage = nil
        isLoadingPreview = true

        Task {
            do {
                let saved: String
                do {
                    saved = try await CoverManager.shared.downloadAndSaveImage(from: candidate.fullURL)
                } catch {
                    saved = try await CoverManager.shared.downloadAndSaveImage(from: candidate.previewURL)
                }
                await MainActor.run {
                    stageTemporaryCover(saved)
                    isLoadingPreview = false
                    if applyImmediately {
                        commitSelection()
                    }
                }
            } catch {
                await MainActor.run {
                    isLoadingPreview = false
                    statusMessage = language.tr("下载该候选封面失败，请尝试其他封面", "Failed to download poster; please try another")
                }
            }
        }
    }

    private func pasteFromClipboard() {
        statusMessage = nil
        switch CoverManager.shared.inspectPasteboard() {
        case .image(let img):
            if let saved = CoverManager.shared.saveImage(img) {
                selectedCandidateID = nil
                stageTemporaryCover(saved)
            } else {
                statusMessage = language.tr("保存剪贴板图片失败", "Failed to save clipboard image")
            }
        case .fileURL(let url):
            if let saved = CoverManager.shared.saveImageFromFileURL(url) {
                selectedCandidateID = nil
                stageTemporaryCover(saved)
            } else {
                statusMessage = language.tr("无法读取剪贴板中的图片文件", "Cannot read image file from clipboard")
            }
        case .remoteURL(let urlStr):
            remoteLinkInput = urlStr
            loadFromLinkInput()
        case .empty:
            statusMessage = language.tr("剪贴板中没有检测到图片或链接", "No image or URL found in clipboard")
        }
    }

    private func loadFromLinkInput() {
        let trimmed = remoteLinkInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        statusMessage = nil
        isLoadingPreview = true

        Task {
            do {
                let saved = try await CoverManager.shared.downloadAndSaveImage(from: trimmed)
                await MainActor.run {
                    selectedCandidateID = nil
                    stageTemporaryCover(saved)
                    remoteLinkInput = ""
                    isLoadingPreview = false
                }
            } catch {
                await MainActor.run {
                    isLoadingPreview = false
                    statusMessage = error.localizedDescription
                }
            }
        }
    }

    private func cleanupUncommittedFiles() {
        for temp in temporaryFiles where temp != initialCoverFileName {
            CoverManager.shared.removeCover(fileName: temp)
        }
    }

    private func commitSelection() {
        let chosen = previewCoverFileName
        for temp in temporaryFiles where temp != chosen && temp != initialCoverFileName {
            CoverManager.shared.removeCover(fileName: temp)
        }
        onCommitCover(chosen)
        dismiss()
    }
}

// MARK: - Candidate Poster Grid Cell

private struct CoverCandidateCard: View {
    let candidate: CoverCandidate
    let isSelected: Bool
    var language: AppLanguage = .zh
    let onSelect: () -> Void

    @State private var loadedImage: NSImage? = nil
    @State private var loadFailed: Bool = false
    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    Color.black.opacity(0.25)
                        .aspectRatio(2.0 / 3.0, contentMode: .fit)
                        .overlay {
                            if let loadedImage {
                                Image(nsImage: loadedImage)
                                    .resizable()
                                    .scaledToFill()
                            } else if loadFailed {
                                VStack(spacing: 4) {
                                    Image(systemName: "photo")
                                        .font(.system(size: 18))
                                    Text(language.tr("预览不可用", "Unavailable"))
                                        .font(.system(size: 10))
                                }
                                .foregroundStyle(.secondary)
                            } else {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(
                                    isSelected
                                        ? Color.accentColor
                                        : Color.white.opacity(isHovered ? 0.35 : 0.14),
                                    lineWidth: isSelected ? 2.5 : 0.8
                                )
                        )
                        .shadow(color: .black.opacity(0.20), radius: 5, x: 0, y: 3)

                    Text(candidate.sourceTag)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(Color.black.opacity(0.65), in: Capsule())
                        .padding(6)
                }
                .scaleEffect(isHovered ? 1.02 : 1.0)
                .animation(.easeOut(duration: 0.14), value: isHovered)

                Text(candidate.title)
                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? Color.accentColor : .primary.opacity(0.88))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .task(id: candidate.previewURL) {
            if let img = await CoverSearchService.shared.loadPreviewImage(from: candidate.previewURL) {
                loadedImage = img
            } else {
                loadFailed = true
            }
        }
    }
}
