import SwiftUI

struct LibraryEmptyStateView: View {
    @Environment(LibraryStore.self) private var store
    let onAddItem: () -> Void

    private var lang: AppLanguage { store.language }
    private var activeCategory: MediaCategory? { store.selectedDestination.activeCategory }

    var body: some View {
        let hasActiveSearch = store.hasActiveFilter
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.primary.opacity(0.05))
                    .frame(width: 68, height: 68)

                Image(systemName: hasActiveSearch ? "magnifyingglass" : (activeCategory?.systemImage ?? "books.vertical"))
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(activeCategory?.accentColor.opacity(0.8) ?? Color.secondary)
            }

            VStack(spacing: 6) {
                Text(
                    !hasActiveSearch
                        ? lang.tr("暂无记录", "No Items Yet")
                        : lang.tr("没有找到匹配项", "No Matching Items")
                )
                .font(.system(size: 15.5, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.90))

                Text(
                    !hasActiveSearch
                        ? lang.tr("点击下方按钮或工具栏「+」开始记录。", "Click below or “+” in the toolbar to start tracking.")
                        : lang.tr("试试换个关键词，或清除筛选条件。", "Try another keyword or clear your active filters.")
                )
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            }

            if !hasActiveSearch {
                HStack(spacing: 10) {
                    Button(action: onAddItem) {
                        Label(lang.tr("添加作品", "Add Item"), systemImage: "plus")
                            .font(.system(size: 12.5, weight: .semibold))
                    }
                    .buttonStyle(
                        ShelfButtonStyle(
                            variant: .primary,
                            horizontalPadding: 16,
                            verticalPadding: 7.5,
                            cornerRadius: 8
                        )
                    )

                    if store.isEmpty {
                        Button {
                            store.restoreSampleItems()
                        } label: {
                            Label(lang.tr("载入示例数据", "Load Sample Data"), systemImage: "sparkles")
                                .font(.system(size: 12.5, weight: .medium))
                        }
                        .buttonStyle(
                            ShelfButtonStyle(
                                variant: .secondary,
                                horizontalPadding: 14,
                                verticalPadding: 7.5,
                                cornerRadius: 8
                            )
                        )
                    }
                }
                .padding(.top, 2)
            } else {
                Button(lang.tr("清除筛选", "Clear Filters")) {
                    store.clearSearch()
                }
                .buttonStyle(
                    ShelfButtonStyle(
                        variant: .secondary,
                        horizontalPadding: 14,
                        verticalPadding: 7,
                        cornerRadius: 8
                    )
                )
            }
        }
        .frame(maxWidth: .infinity)
    }
}
