import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PosterCardView: View {
    let item: MediaItem
    let isSelected: Bool
    let showStatusBadge: Bool
    let onSelect: () -> Void
    let onDoubleClickEdit: () -> Void
    let onReplaceCover: () -> Void

    @EnvironmentObject private var store: LibraryStore
    @State private var isHovered = false
    @State private var isDropTargeted = false

    private var lang: AppLanguage { store.language }

    var body: some View {
        let shownTitle = item.displayTitle(in: lang)

        Button {
            onSelect()
            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
                onDoubleClickEdit()
            }
        } label: {
            VStack(alignment: .center, spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.black)
                        .shadow(color: Color.black.opacity(0.24), radius: 8, x: 0, y: 4)

                    CoverArtworkView(
                        title: shownTitle,
                        category: item.category,
                        subtag: item.subtag,
                        coverFileName: item.coverFileName,
                        paletteSeed: item.paletteSeed,
                        language: lang,
                        cornerRadius: 10,
                        isHovered: isHovered || isSelected,
                        useThumbnail: true
                    )
                    .equatable()

                    if isSelected {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: 2.5)
                            .allowsHitTesting(false)
                    }

                    if isHovered || showStatusBadge {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(item.status.tintColor)
                                .frame(width: 6, height: 6)
                            if isHovered {
                                Text(item.category.statusLabel(for: item.status, in: lang))
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .padding(.horizontal, isHovered ? 7 : 5)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.66), in: Capsule())
                        .overlay(
                            Capsule()
                                .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
                        )
                        .padding(7)
                        .allowsHitTesting(false)
                    }

                    if isDropTargeted {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.accentColor.opacity(0.32))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, dash: [6, 4]))
                            )
                            .overlay(
                                VStack(spacing: 5) {
                                    Image(systemName: "photo.badge.plus")
                                        .font(.system(size: 20, weight: .semibold))
                                    Text(lang.tr("松开设为海报", "Drop to Set Cover"))
                                        .font(.system(size: 11, weight: .semibold))
                                }
                                .foregroundStyle(.white)
                                .padding(10)
                                .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            )
                            .allowsHitTesting(false)
                    }
                }
                .scaleEffect(isHovered ? 1.028 : 1.0)
                .offset(y: isHovered ? -2 : 0)
                .animation(.easeOut(duration: 0.16), value: isHovered)

                VStack(spacing: 3) {
                    Text(shownTitle)
                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.primary.opacity(0.92))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity)

                    if item.rating > 0 {
                        HStack(spacing: 1.5) {
                            ForEach(1...item.rating, id: \.self) { _ in
                                Image(systemName: "star.fill")
                                    .font(.system(size: 8.5))
                                    .foregroundStyle(Color(red: 0.96, green: 0.74, blue: 0.20))
                            }
                        }
                        .frame(height: 11)
                    }
                }
                .padding(.horizontal, 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PosterCardPressStyle())
        .onHover { hovering in
            if isHovered != hovering {
                isHovered = hovering
            }
        }
        .onDrop(of: [.fileURL, .image, .url], isTargeted: $isDropTargeted) { providers in
            CoverManager.shared.extractDroppedCover(from: providers) { result in
                switch result {
                case .success(let savedFileName):
                    store.updateCover(for: item.id, newCoverFileName: savedFileName)
                case .failure(let err):
                    store.showToast(err.localizedDescription)
                }
            }
        }
        .contextMenu {
            Section(lang.tr("切换状态", "Status")) {
                ForEach(TrackingStatus.filterOrder) { status in
                    Button {
                        store.updateStatus(for: item.id, to: status)
                    } label: {
                        Label(
                            item.category.statusLabel(for: status, in: lang),
                            systemImage: item.status == status ? "checkmark.circle.fill" : status.systemImage
                        )
                    }
                }
            }

            Section(lang.tr("快速评分", "Quick Rating")) {
                ForEach([5, 4, 3, 2, 1], id: \.self) { stars in
                    Button {
                        store.updateRating(for: item.id, rating: stars)
                    } label: {
                        Text(String(repeating: "★", count: stars) + String(repeating: "☆", count: 5 - stars))
                    }
                }
                if item.rating > 0 {
                    Button(lang.tr("清除评分", "Clear Rating")) {
                        store.updateRating(for: item.id, rating: 0)
                    }
                }
            }

            Section(lang.tr("封面与编辑", "Cover & Edit")) {
                Button {
                    onReplaceCover()
                } label: {
                    Label(lang.tr("更换封面…", "Change Cover…"), systemImage: "photo.on.rectangle.angled")
                }

                Button {
                    if let url = CoverManager.shared.chooseLocalImagePanel(lang: lang),
                       let saved = CoverManager.shared.saveImageFromFileURL(url) {
                        store.updateCover(for: item.id, newCoverFileName: saved)
                    }
                } label: {
                    Label(lang.tr("选择本地图片…", "Choose Local Image…"), systemImage: "folder")
                }

                Button {
                    pasteCoverForItem()
                } label: {
                    Label(lang.tr("从剪贴板粘贴封面", "Paste Cover from Clipboard"), systemImage: "doc.on.clipboard")
                }

                if item.coverFileName != nil {
                    Button {
                        store.updateCover(for: item.id, newCoverFileName: nil)
                    } label: {
                        Label(lang.tr("恢复默认封面", "Reset Default Cover"), systemImage: "arrow.uturn.backward")
                    }
                }

                Divider()

                Button {
                    onSelect()
                    onDoubleClickEdit()
                } label: {
                    Label(lang.tr("编辑作品信息…", "Edit Info…"), systemImage: "slider.horizontal.3")
                }

                Button(role: .destructive) {
                    store.deleteItem(id: item.id)
                } label: {
                    Label(lang.tr("删除", "Delete"), systemImage: "trash")
                }
            }
        }
    }

    private func pasteCoverForItem() {
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
            store.showToast(lang.tr("剪贴板中没有检测到图片或图片链接", "No image or image URL found in clipboard"))
        }
    }
}

private struct PosterCardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1.0)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
    }
}
