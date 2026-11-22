import AppKit

@MainActor
enum PosterCardContextMenu {
    static func build(
        for item: LibraryPoster,
        language lang: AppLanguage,
        coordinator: NativePosterGrid.Coordinator
    ) -> NSMenu {
        let menu = NSMenu()

        // Status section
        menu.addItem(NSMenuItem.sectionHeader(title: lang.tr("切换状态", "Status")))
        for st in TrackingStatus.filterOrder {
            menu.addItem(ClosureMenuItem(
                title: item.category.statusLabel(for: st, in: lang),
                systemImage: st.systemImage,
                state: item.status == st ? .on : .off
            ) { [weak coordinator] in
                coordinator?.parent.actions.onChangeStatus(item.id, st)
            })
        }

        menu.addItem(.separator())

        // Rating section
        menu.addItem(NSMenuItem.sectionHeader(title: lang.tr("快速评分", "Quick Rating")))
        for stars in [5, 4, 3, 2, 1] {
            let label = String(repeating: "★", count: stars) + String(repeating: "☆", count: 5 - stars)
            menu.addItem(ClosureMenuItem(
                title: label,
                state: item.rating == stars ? .on : .off
            ) { [weak coordinator] in
                coordinator?.parent.actions.onChangeRating(item.id, stars)
            })
        }
        if item.rating > 0 {
            menu.addItem(ClosureMenuItem(title: lang.tr("清除评分", "Clear Rating")) { [weak coordinator] in
                coordinator?.parent.actions.onChangeRating(item.id, 0)
            })
        }

        menu.addItem(.separator())

        // Cover & Edit section
        menu.addItem(NSMenuItem.sectionHeader(title: lang.tr("封面与编辑", "Cover & Edit")))

        menu.addItem(ClosureMenuItem(
            title: lang.tr("更换封面…", "Change Cover…"),
            systemImage: "photo.on.rectangle.angled"
        ) { [weak coordinator] in
            coordinator?.parent.actions.onRequestReplaceCover(item.id)
        })

        menu.addItem(ClosureMenuItem(
            title: lang.tr("选择本地图片…", "Choose Local Image…"),
            systemImage: "folder"
        ) { [weak coordinator] in
            guard let coordinator, let url = CoverManager.shared.chooseLocalImagePanel(lang: lang) else { return }
            coordinator.parent.actions.onImportCover(item.id, .file(url))
        })

        menu.addItem(ClosureMenuItem(
            title: lang.tr("从剪贴板粘贴封面", "Paste Cover from Clipboard"),
            systemImage: "doc.on.clipboard"
        ) { [weak coordinator] in
            guard let coordinator else { return }
            if let source = CoverManager.shared.inspectPasteboard() {
                coordinator.parent.actions.onImportCover(item.id, source)
            } else {
                coordinator.parent.actions.onShowToast(
                    lang.tr("剪贴板中没有检测到图片或图片链接", "No image or image URL in clipboard")
                )
            }
        })

        if item.coverFileName != nil {
            menu.addItem(ClosureMenuItem(
                title: lang.tr("恢复默认封面", "Reset Default Cover"),
                systemImage: "arrow.uturn.backward"
            ) { [weak coordinator] in
                coordinator?.parent.actions.onUpdateCoverFileName(item.id, nil)
            })
        }

        menu.addItem(.separator())

        menu.addItem(ClosureMenuItem(
            title: lang.tr("设置标签…", "Tags…"),
            systemImage: "tag"
        ) { [weak coordinator] in
            coordinator?.parent.actions.onRequestEditTags(item.id)
        })

        menu.addItem(ClosureMenuItem(
            title: lang.tr("编辑作品信息…", "Edit Info…"),
            systemImage: "slider.horizontal.3"
        ) { [weak coordinator] in
            coordinator?.parent.actions.onDoubleClickEdit(item.id)
        })

        menu.addItem(ClosureMenuItem(
            title: lang.tr("删除", "Delete"),
            systemImage: "trash"
        ) { [weak coordinator] in
            coordinator?.parent.actions.onDeleteItem(item.id)
        })

        return menu
    }
}
