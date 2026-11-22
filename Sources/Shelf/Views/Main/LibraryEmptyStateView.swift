import SwiftUI

struct LibraryEmptyStateView: View {
    @Environment(LibraryStore.self) private var store
    let onAddItem: () -> Void

    private var lang: AppLanguage { store.language }
    private var activeCategory: MediaCategory? { store.selectedDestination.activeCategory }

    var body: some View {
        let hasActiveSearch = store.hasActiveFilter
        VStack(spacing: 14) {
            Image(systemName: activeCategory?.systemImage ?? "books.vertical")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.secondary.opacity(0.7))

            Text(
                !hasActiveSearch
                    ? lang.tr("暂无记录", "No Items Yet")
                    : lang.tr("没有找到匹配项", "No Matching Items")
            )
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.primary.opacity(0.85))

            Text(
                !hasActiveSearch
                    ? lang.tr("点击下方按钮或右上角「添加作品」开始记录。", "Click below or “Add Item” in the top-right to start tracking.")
                    : lang.tr("试试换个关键词，或清除筛选条件。", "Try another keyword or clear your active filters.")
            )
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 380)

            if !hasActiveSearch {
                HStack(spacing: 12) {
                    Button(action: onAddItem) {
                        Label(lang.tr("添加作品", "Add Item"), systemImage: "plus")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .buttonStyle(
                        ShelfButtonStyle(
                            variant: .primary,
                            horizontalPadding: 18,
                            verticalPadding: 8,
                            cornerRadius: 9
                        )
                    )

                    if store.isEmpty {
                        Button {
                            store.restoreSampleItems()
                        } label: {
                            Label(lang.tr("载入示例数据", "Load Sample Data"), systemImage: "sparkles")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .buttonStyle(
                            ShelfButtonStyle(
                                variant: .secondary,
                                horizontalPadding: 16,
                                verticalPadding: 8,
                                cornerRadius: 9
                            )
                        )
                    }
                }
                .padding(.top, 6)
            } else {
                Button(lang.tr("清除搜索", "Clear Search")) {
                    store.clearSearch()
                }
                .buttonStyle(
                    ShelfButtonStyle(
                        variant: .secondary,
                        horizontalPadding: 16,
                        verticalPadding: 7,
                        cornerRadius: 8
                    )
                )
            }
        }
        .frame(maxWidth: .infinity)
    }
}
