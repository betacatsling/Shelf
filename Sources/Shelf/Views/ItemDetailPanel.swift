import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ItemDetailPanel: View {
    let item: MediaItem
    let onReplaceCover: () -> Void
    let onEditTapped: () -> Void
    let onClose: () -> Void

    @EnvironmentObject private var store: LibraryStore
    @State private var draftNotes: String = ""
    @State private var isPosterHovered = false
    @State private var isDropTargeted = false
    @State private var showDeleteConfirm = false

    private var lang: AppLanguage { store.language }

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return df
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                heroHeader

                VStack(alignment: .leading, spacing: 20) {
                    statusSwitcherSection
                    ratingSection
                    notesSection
                    metadataFooter
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
        .frame(minWidth: 305, idealWidth: 330, maxWidth: 360)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            draftNotes = item.notes
        }
        .onChange(of: item.id) { _, _ in
            draftNotes = item.notes
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

    private var heroHeader: some View {
        let shownTitle = item.displayTitle(in: lang)

        return ZStack(alignment: .topTrailing) {
            ZStack {
                if let nsImg = CoverManager.shared.gridThumbnail(for: item.coverFileName) {
                    Image(nsImage: nsImg)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .frame(height: 245)
                        .blur(radius: 30)
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

            VStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.black)
                        .frame(width: 132, height: 198)
                        .shadow(color: .black.opacity(0.30), radius: 12, x: 0, y: 6)

                    CoverArtworkView(
                        title: shownTitle,
                        category: item.category,
                        subtag: item.subtag,
                        coverFileName: item.coverFileName,
                        paletteSeed: item.paletteSeed,
                        language: lang,
                        cornerRadius: 12,
                        isHovered: isPosterHovered,
                        useThumbnail: false
                    )
                    .frame(width: 132, height: 198)

                    if isPosterHovered || isDropTargeted {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.black.opacity(0.60))
                            .frame(width: 132, height: 198)
                            .overlay(
                                VStack(spacing: 7) {
                                    posterOverlayButton(
                                        title: lang.tr("更换封面", "Change Cover"),
                                        icon: "photo.on.rectangle.angled"
                                    ) {
                                        onReplaceCover()
                                    }

                                    posterOverlayButton(
                                        title: lang.tr("本地选图", "Local Image"),
                                        icon: "folder"
                                    ) {
                                        if let url = CoverManager.shared.chooseLocalImagePanel(lang: lang),
                                           let saved = CoverManager.shared.saveImageFromFileURL(url) {
                                            store.updateCover(for: item.id, newCoverFileName: saved)
                                        }
                                    }

                                    posterOverlayButton(
                                        title: lang.tr("粘贴图片", "Paste Image"),
                                        icon: "doc.on.clipboard"
                                    ) {
                                        pasteCover()
                                    }
                                }
                            )
                    }
                }
                .onHover { isPosterHovered = $0 }
                .onDrop(of: [.fileURL, .image, .url], isTargeted: $isDropTargeted) { providers in
                    CoverManager.shared.extractDroppedCover(from: providers) { result in
                        if case .success(let saved) = result {
                            store.updateCover(for: item.id, newCoverFileName: saved)
                        }
                    }
                }

                VStack(spacing: 8) {
                    Text(shownTitle)
                        .font(.system(size: 16.5, weight: .bold))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)

                    HStack(spacing: 6) {
                        Label(item.category.title(in: lang), systemImage: item.category.systemImage)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(item.category.accentColor)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3.5)
                            .background(item.category.accentColor.opacity(0.14), in: Capsule())

                        if !item.subtag.isEmpty {
                            let shownTag = MediaCategory.localizedSubtag(item.subtag, in: lang)
                            let prefix = item.category.subtagShortLabel(in: lang)
                            Text(lang == .zh ? "\(prefix)：\(shownTag)" : "\(prefix): \(shownTag)")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 3.5)
                                .background(Color.primary.opacity(0.08), in: Capsule())
                        }
                    }

                    HStack(spacing: 6) {
                        Button(action: onReplaceCover) {
                            Label(lang.tr("更换封面…", "Change Cover…"), systemImage: "photo.on.rectangle.angled")
                                .font(.system(size: 11.5, weight: .medium))
                        }
                        .buttonStyle(
                            ShelfButtonStyle(
                                variant: .secondary,
                                horizontalPadding: 11,
                                verticalPadding: 5,
                                cornerRadius: 7
                            )
                        )

                        Button {
                            if let url = CoverManager.shared.chooseLocalImagePanel(lang: lang),
                               let saved = CoverManager.shared.saveImageFromFileURL(url) {
                                store.updateCover(for: item.id, newCoverFileName: saved)
                            }
                        } label: {
                            Label(lang.tr("本地选图", "Local Image"), systemImage: "folder")
                                .font(.system(size: 11.5, weight: .medium))
                        }
                        .buttonStyle(
                            ShelfButtonStyle(
                                variant: .secondary,
                                horizontalPadding: 10,
                                verticalPadding: 5,
                                cornerRadius: 7
                            )
                        )
                    }
                    .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 24)

            ShelfIconButton(
                systemName: "xmark",
                size: 28,
                iconSize: 11,
                helpText: lang.tr("收起详情栏", "Hide Details"),
                action: onClose
            )
            .padding(12)
        }
    }

    private func posterOverlayButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.20), in: Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(Color.white.opacity(0.32), lineWidth: 0.8)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

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
                    .frame(minHeight: 135)
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

        return VStack(spacing: 12) {
            HStack {
                Text(lang.tr("记录于 \(createdStr)", "Added \(createdStr)"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Spacer()
                if updatedStr != createdStr {
                    Text(lang.tr("更新于 \(updatedStr)", "Updated \(updatedStr)"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                Button(action: onEditTapped) {
                    Label(lang.tr("编辑信息", "Edit Info"), systemImage: "slider.horizontal.3")
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .buttonStyle(
                    ShelfButtonStyle(
                        variant: .secondary,
                        horizontalPadding: 14,
                        verticalPadding: 8,
                        cornerRadius: 8,
                        fullWidth: true
                    )
                )

                Button {
                    showDeleteConfirm = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12.5, weight: .medium))
                }
                .buttonStyle(
                    ShelfButtonStyle(
                        variant: .destructive,
                        horizontalPadding: 12,
                        verticalPadding: 8,
                        cornerRadius: 8,
                        fullWidth: false
                    )
                )
                .help(lang.tr("删除", "Delete"))
            }
        }
    }

    private func pasteCover() {
        switch CoverManager.shared.inspectPasteboard() {
        case .image(let img):
            if let saved = CoverManager.shared.saveImage(img) {
                store.updateCover(for: item.id, newCoverFileName: saved)
            }
        case .fileURL(let url):
            if let saved = CoverManager.shared.saveImageFromFileURL(url) {
                store.updateCover(for: item.id, newCoverFileName: saved)
            }
        case .remoteURL(let urlStr):
            Task {
                do {
                    let saved = try await CoverManager.shared.downloadAndSaveImage(from: urlStr)
                    store.updateCover(for: item.id, newCoverFileName: saved)
                } catch {
                    store.showToast(error.localizedDescription)
                }
            }
        case .empty:
            store.showToast(lang.tr("剪贴板中没有检测到图片或链接", "No image or link found in clipboard"))
        }
    }
}
