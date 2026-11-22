import SwiftUI

struct TagFilterToolbarMenu: View {
    @Environment(LibraryStore.self) private var store
    let untaggedCountInView: Int

    private var lang: AppLanguage { store.language }

    var body: some View {
        let sections = TagCatalog.groupedOutline(categories: store.tagCategories, nodes: store.tagNodes)
        let untaggedCount = untaggedCountInView > 0 ? untaggedCountInView : store.totalUntaggedCount

        Menu {
            if store.hasActiveTagFilter {
                Button(lang.tr("清除标签筛选", "Clear Tag Filters")) {
                    store.searchTokens.removeAll()
                    store.filterUntaggedOnly = false
                }
                Divider()
            }

            if untaggedCount > 0 || store.filterUntaggedOnly {
                let noTagLabel = untaggedCount > 0
                    ? "\(lang.tr("无标签", "No Tag")) (\(untaggedCount))"
                    : lang.tr("无标签", "No Tag")
                Button {
                    store.toggleUntaggedFilter()
                } label: {
                    if store.filterUntaggedOnly {
                        Label(noTagLabel, systemImage: "checkmark")
                    } else {
                        Text(noTagLabel)
                    }
                }
                Divider()
            }

            if sections.isEmpty {
                Text(lang.tr("暂无标签", "No Tags"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(sections) { section in
                    let sectionTitle = section.category.map { MediaCategory.localizedTag($0, in: lang) }
                        ?? lang.tr("未分类", "Uncategorized")
                    Section(sectionTitle) {
                        ForEach(section.rows) { row in
                            let count = store.usageCount(
                                forTag: row.node.name,
                                in: store.selectedDestination,
                                includeDescendants: true
                            )
                            let indent = String(repeating: "  ", count: row.depth)
                            let localized = MediaCategory.localizedTag(row.node.name, in: lang)
                            let title = count > 0 ? "\(indent)\(localized) (\(count))" : "\(indent)\(localized)"
                            Button {
                                store.toggleSearchTag(row.node.name)
                            } label: {
                                if store.hasSearchTag(row.node.name) {
                                    Label(title, systemImage: "checkmark")
                                } else {
                                    Text(title)
                                }
                            }
                        }
                    }
                }
            }

            Divider()

            Button {
                TagWindowController.shared.show(store: store)
            } label: {
                Label(lang.tr("管理标签… (⌃⌘T)", "Manage Tags… (⌃⌘T)"), systemImage: "slider.horizontal.3")
            }
        } label: {
            Label(
                lang.tr("按标签筛选", "Filter by Tag"),
                systemImage: store.hasActiveTagFilter ? "tag.fill" : "tag"
            )
        }
        .help(lang.tr("按标签筛选", "Filter by Tag"))
    }
}
