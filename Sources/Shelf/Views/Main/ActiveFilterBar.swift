import SwiftUI

struct ActiveFilterBar: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let library: LibraryProjection

    private var lang: AppLanguage { store.language }

    var body: some View {
        let trimmedQuery = store.searchText.trimmed
        let suggestions = store.narrowingTags(for: library)

        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if store.filterUntaggedOnly {
                        ActiveFilterPill(
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
                        ActiveFilterPill(icon: "tag.fill", title: label, isAccent: true) {
                            store.toggleSearchTag(token.tag)
                        }
                    }

                    if !trimmedQuery.isEmpty {
                        ActiveFilterPill(icon: "magnifyingglass", title: "“\(trimmedQuery)”", isAccent: false) {
                            store.searchText = ""
                        }
                    }

                    if !suggestions.isEmpty {
                        Text("·")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 2)

                        ForEach(suggestions, id: \.self) { tag in
                            NarrowingTagPill(title: MediaCategory.localizedTag(tag, in: lang)) {
                                store.refineTagFilter(with: tag)
                            }
                        }
                    }
                }
                .padding(.vertical, 1)
                .animation(reduceMotion ? nil : ShelfMotion.control, value: store.searchTokens)
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
}

private struct ActiveFilterPill: View {
    let icon: String
    let title: String
    let isAccent: Bool
    let onRemove: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        Button(action: onRemove) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .opacity(isHovered ? 1.0 : 0.72)
            }
            .foregroundStyle(isAccent ? Color.white : Color.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 3.5)
            .background(
                Capsule().fill(
                    isAccent
                        ? Color.accentColor.opacity(isHovered ? 0.88 : 1.0)
                        : Color.primary.opacity(isHovered ? 0.14 : 0.09)
                )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : ShelfMotion.micro, value: isHovered)
        .onHover { isHovered = $0 }
        .transition(.scale(scale: 0.90).combined(with: .opacity))
    }
}

private struct NarrowingTagPill: View {
    let title: String
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(isHovered ? Color.primary : Color.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 3.5)
                .background(Color.primary.opacity(isHovered ? 0.09 : 0.048), in: Capsule())
                .overlay(
                    Capsule().strokeBorder(Color.primary.opacity(isHovered ? 0.16 : 0.09), lineWidth: 0.7)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : ShelfMotion.micro, value: isHovered)
        .onHover { isHovered = $0 }
    }
}
