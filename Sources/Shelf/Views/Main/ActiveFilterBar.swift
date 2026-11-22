import SwiftUI

struct ActiveFilterBar: View {
    @Environment(LibraryStore.self) private var store
    let library: LibraryProjection

    private var lang: AppLanguage { store.language }

    var body: some View {
        let trimmedQuery = store.searchText.trimmed
        let suggestions = store.narrowingTags(for: library)

        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if store.filterUntaggedOnly {
                        activeFilterPill(
                            icon: "tag.slash",
                            title: lang.tr("无标签", "No Tag"),
                            isAccent: true
                        ) {
                            store.filterUntaggedOnly = false
                        }
                    }

                    ForEach(store.searchTokens) { token in
                        let ancestors = store.tagAncestors(of: token.tag)
                        let localized = MediaCategory.localizedTag(token.tag, in: lang)
                        let label = ancestors.isEmpty
                            ? localized
                            : "\(TagCatalog.formattedBreadcrumb(ancestors: ancestors, language: lang)) › \(localized)"
                        activeFilterPill(icon: "tag.fill", title: label, isAccent: true) {
                            store.toggleSearchTag(token.tag)
                        }
                    }

                    if !trimmedQuery.isEmpty {
                        activeFilterPill(icon: "magnifyingglass", title: "“\(trimmedQuery)”", isAccent: false) {
                            store.searchText = ""
                        }
                    }

                    if !suggestions.isEmpty {
                        Text("·")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 2)

                        ForEach(suggestions, id: \.self) { tag in
                            Button {
                                store.refineTagFilter(with: tag)
                            } label: {
                                Text(MediaCategory.localizedTag(tag, in: lang))
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 3.5)
                                    .background(Color.primary.opacity(0.055), in: Capsule())
                                    .overlay(
                                        Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.7)
                                    )
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.vertical, 1)
            }

            Button(lang.tr("清除", "Clear")) {
                store.clearSearch()
            }
            .buttonStyle(
                ShelfButtonStyle(
                    variant: .subtle,
                    horizontalPadding: 8,
                    verticalPadding: 3,
                    cornerRadius: 6
                )
            )
            .font(.system(size: 11.5, weight: .medium))
            .help(lang.tr("清除所有筛选 (⌃Esc)", "Clear all filters (⌃Esc)"))
        }
        .padding(.horizontal, ShelfTheme.horizontalPadding)
        .padding(.vertical, 7)
    }

    private func activeFilterPill(icon: String, title: String, isAccent: Bool, onRemove: @escaping () -> Void) -> some View {
        Button(action: onRemove) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold)).opacity(0.85)
            }
            .foregroundStyle(isAccent ? Color.white : Color.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 3.5)
            .background(Capsule().fill(isAccent ? Color.accentColor : Color.primary.opacity(0.10)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
