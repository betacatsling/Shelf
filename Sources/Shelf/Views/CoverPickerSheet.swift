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

    @State private var coverController = CoverImportController()
    @State private var searchQuery: String = ""
    @State private var searchAllCategories: Bool = false
    @State private var candidates: [CoverCandidate] = []
    @State private var isSearching: Bool = false
    @State private var hasSearchedOnce: Bool = false
    @State private var selectedCandidateID: String? = nil

    @State private var remoteLinkInput: String = ""
    @State private var activeSearchTask: Task<Void, Never>?
    @State private var preparedCandidate: (id: String, fileName: String)?
    @State private var applyCandidateImmediately = false

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            ShelfHairline()

            HStack(alignment: .top, spacing: 0) {
                leftManualPanel.frame(width: 236)
                ShelfHairline(vertical: true)
                rightOnlineSearchPanel.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: 468)

            ShelfHairline()

            SheetFooterBar(
                errorMessage: coverController.errorMessage,
                cancelTitle: language.tr("取消", "Cancel"),
                confirmTitle: language.tr("保存封面", "Save Cover"),
                confirmDisabled: coverController.isLoading,
                horizontalPadding: 22,
                verticalPadding: 13,
                onCancel: { dismiss() },
                onConfirm: commitSelection
            )
        }
        .frame(width: 760)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            coverController.resetInitialCover(initialCoverFileName)
            let trimmed = itemTitle.trimmed
            searchQuery = trimmed
            if !trimmed.isEmpty {
                triggerOnlineSearch()
            }
        }
        .onDisappear {
            activeSearchTask?.cancel()
            coverController.tearDownAndCleanupUncommitted()
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

            if !itemTitle.trimmed.isEmpty {
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
            CoverDropPreviewView(
                coverFileName: coverController.coverFileName,
                title: itemTitle.isEmpty ? language.tr("封面预览", "Cover Preview") : itemTitle,
                category: category,
                subtag: subtag,
                paletteSeed: paletteSeed,
                language: language,
                width: 156,
                height: 234,
                isDropTargeted: coverController.isDropTargeted,
                isLoading: coverController.isLoading,
                dropPrompt: language.tr("松开替换封面", "Drop to Replace"),
                loadingPrompt: language.tr("正在载入图片…", "Loading image…")
            )
            .padding(.top, 4)

            VStack(spacing: 8) {
                Button {
                    coverController.chooseLocalImage(language: language) {
                        selectedCandidateID = nil
                        applyCandidateImmediately = false
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
                    coverController.pasteFromClipboard(
                        language: language,
                        onWillStart: { source in
                            selectedCandidateID = nil
                            applyCandidateImmediately = false
                            if case .remote(let url) = source { remoteLinkInput = url }
                        },
                        onSuccess: { _ in
                            remoteLinkInput = ""
                        }
                    )
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
                        .onSubmit(loadFromLinkInput)

                    Button(language.tr("读取", "Load"), action: loadFromLinkInput)
                        .buttonStyle(
                            ShelfButtonStyle(
                                variant: .secondary,
                                horizontalPadding: 9,
                                verticalPadding: 4.5,
                                cornerRadius: 6
                            )
                        )
                        .font(.system(size: 11.5, weight: .medium))
                        .disabled(remoteLinkInput.trimmed.isEmpty || coverController.isLoading)
                }
                .padding(.top, 2)

                if coverController.coverFileName != nil {
                    Button {
                        applyCandidateImmediately = false
                        selectedCandidateID = nil
                        coverController.resetToDefaultCover()
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
        .onDrop(of: [.fileURL, .image, .url], isTargeted: $coverController.isDropTargeted) { providers in
            coverController.handleDrop(
                providers: providers,
                language: language,
                onWillStart: {
                    selectedCandidateID = nil
                    applyCandidateImmediately = false
                }
            )
        }
    }

    // MARK: - Right Column: Online Visual Poster Search

    private var rightOnlineSearchPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ShelfSearchBar(
                    placeholder: language.tr("输入作品名称搜索海报…", "Search posters by title…"),
                    text: $searchQuery,
                    font: .systemFont(ofSize: 13),
                    iconSize: 12.5,
                    horizontalPadding: 10,
                    verticalPadding: 6.5,
                    cornerRadius: 8,
                    fillOpacity: 0.06,
                    borderOpacity: 0.14,
                    onSubmit: { _ in triggerOnlineSearch() },
                    interceptSubmitWhenEmpty: false,
                    interceptEscapeWhenEmpty: false
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
                    if !searchQuery.trimmed.isEmpty {
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
                .disabled(searchQuery.trimmed.isEmpty || isSearching)
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)

            if isSearching && candidates.isEmpty {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.regular)
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
                        ProgressView().controlSize(.mini)
                    }
                    Spacer()
                }
                .padding(.horizontal, 18)

                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 118, maximum: 148), spacing: 14)],
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

    // MARK: - Actions

    private func triggerOnlineSearch() {
        let trimmed = searchQuery.trimmed
        guard !trimmed.isEmpty else { return }

        activeSearchTask?.cancel()
        isSearching = true
        candidates = []
        coverController.errorMessage = nil

        let targetCategory: MediaCategory? = searchAllCategories ? nil : category
        let activeLang = language
        activeSearchTask = Task {
            await CoverSearchService.shared.searchCoversProgressively(
                query: trimmed,
                category: targetCategory,
                language: activeLang
            ) { partial in
                if self.candidates != partial { self.candidates = partial }
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.hasSearchedOnce = true
                self.isSearching = false
            }
        }
    }

    private func selectCandidate(_ candidate: CoverCandidate, applyImmediately: Bool) {
        if selectedCandidateID == candidate.id && coverController.isLoading {
            applyCandidateImmediately = applyCandidateImmediately || applyImmediately
            return
        }
        coverController.cancelImport()
        applyCandidateImmediately = false
        selectedCandidateID = candidate.id
        coverController.errorMessage = nil
        if let preparedCandidate, preparedCandidate.id == candidate.id {
            coverController.coverFileName = preparedCandidate.fileName
            if applyImmediately { commitSelection() }
            return
        }

        applyCandidateImmediately = applyImmediately
        coverController.importCandidate(
            fullURL: candidate.fullURL,
            previewURL: candidate.previewURL,
            failureMessage: language.tr("下载该候选封面失败，请尝试其他封面", "Failed to download poster; please try another"),
            onSuccess: { saved in
                preparedCandidate = (candidate.id, saved)
                let shouldCommit = applyCandidateImmediately
                applyCandidateImmediately = false
                if shouldCommit { commitSelection() }
            },
            onFailure: {
                applyCandidateImmediately = false
            }
        )
    }

    private func loadFromLinkInput() {
        let trimmed = remoteLinkInput.trimmed
        guard !trimmed.isEmpty else { return }
        selectedCandidateID = nil
        applyCandidateImmediately = false
        coverController.importCover(.remote(trimmed)) { _ in
            remoteLinkInput = ""
        }
    }

    private func commitSelection() {
        let chosen = coverController.commitAndCleanupUnused()
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var loadedImage: CGImage? = nil
    @State private var loadFailed: Bool = false
    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    Color.black.opacity(0.22)
                        .aspectRatio(2.0 / 3.0, contentMode: .fit)
                        .overlay {
                            if let loadedImage {
                                Image(decorative: loadedImage, scale: 2)
                                    .resizable()
                                    .scaledToFill()
                                    .transition(.opacity)
                            } else if loadFailed {
                                VStack(spacing: 4) {
                                    Image(systemName: "photo").font(.system(size: 18))
                                    Text(language.tr("预览不可用", "Unavailable")).font(.system(size: 10))
                                }
                                .foregroundStyle(.secondary)
                            } else {
                                ProgressView().controlSize(.small)
                            }
                        }
                        .animation(reduceMotion ? nil : ShelfMotion.gentle, value: loadedImage != nil)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(
                                    isSelected ? Color.accentColor : Color.white.opacity(isHovered ? 0.35 : 0.14),
                                    lineWidth: isSelected ? 2.2 : 0.8
                                )
                        )
                        .shadow(
                            color: isSelected
                                ? Color.accentColor.opacity(0.28)
                                : .black.opacity(isHovered ? 0.32 : 0.18),
                            radius: isHovered ? 10 : 5,
                            x: 0,
                            y: isHovered ? 5 : 3
                        )

                    Text(candidate.sourceTag)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(Color.black.opacity(0.62), in: Capsule())
                        .padding(6)
                }
                .overlay(alignment: .topLeading) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white, Color.accentColor)
                            .shadow(color: .black.opacity(0.35), radius: 3, x: 0, y: 1)
                            .padding(6)
                            .transition(.scale(scale: 0.7).combined(with: .opacity))
                    }
                }
                .scaleEffect(!reduceMotion && isHovered ? 1.028 : 1.0)
                .offset(y: !reduceMotion && isHovered ? -2 : 0)
                .animation(reduceMotion ? nil : ShelfMotion.micro, value: isHovered)
                .animation(reduceMotion ? nil : ShelfMotion.micro, value: isSelected)

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
            loadFailed = false
            loadedImage = nil
            let image = await CoverSearchService.shared.loadPreviewImage(from: candidate.previewURL)
            guard !Task.isCancelled else { return }
            loadedImage = image
            loadFailed = image == nil
        }
    }
}
