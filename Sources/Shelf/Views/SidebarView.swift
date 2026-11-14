import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var store: LibraryStore

    private var lang: AppLanguage { store.language }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 3) {
                    sectionHeader(lang.tr("分类", "Library"))

                    SidebarRowButton(
                        title: SidebarDestination.all.title(in: lang),
                        icon: "square.grid.2x2.fill",
                        tint: .accentColor,
                        count: store.count(for: .all),
                        isSelected: store.selectedDestination == .all
                    ) {
                        store.selectDestination(.all)
                    }

                    ForEach(MediaCategory.allCases) { category in
                        let dest: SidebarDestination = .category(category)
                        SidebarRowButton(
                            title: category.title(in: lang),
                            icon: category.systemImage,
                            tint: category.accentColor,
                            count: store.count(for: dest),
                            isSelected: store.selectedDestination == dest
                        ) {
                            store.selectDestination(dest)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    sectionHeader(lang.tr("状态", "Status"))

                    ForEach(TrackingStatus.filterOrder) { status in
                        let dest: SidebarDestination = .status(status)
                        SidebarRowButton(
                            title: status.genericTitle(in: lang),
                            icon: status.systemImage,
                            tint: status.tintColor,
                            count: store.count(for: dest),
                            isSelected: store.selectedDestination == dest
                        ) {
                            store.selectDestination(dest)
                        }
                    }

                    SidebarRowButton(
                        title: SidebarDestination.fiveStar.title(in: lang),
                        icon: "star.fill",
                        tint: Color(red: 0.96, green: 0.72, blue: 0.18),
                        count: store.count(for: .fiveStar),
                        isSelected: store.selectedDestination == .fiveStar
                    ) {
                        store.selectDestination(.fiveStar)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 12)
            .padding(.bottom, 16)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Divider()
                    .opacity(0.5)

                if store.hasSampleItems {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text(lang.tr("包含示例数据", "Sample Data"))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(lang.tr("清空", "Clear")) {
                            store.clearSampleItems()
                        }
                        .buttonStyle(
                            ShelfButtonStyle(
                                variant: .secondary,
                                horizontalPadding: 8,
                                verticalPadding: 3,
                                cornerRadius: 6
                            )
                        )
                        .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 12)
                }

                HStack(spacing: 8) {
                    Image(systemName: "globe")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)

                    ShelfSegmentedControl(
                        segments: [
                            .init(value: AppLanguage.zh, title: "中文"),
                            .init(value: AppLanguage.en, title: "English")
                        ],
                        selection: $store.language,
                        verticalPadding: 4
                    )
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.bottom, 3)
    }
}

private struct SidebarRowButton: View {
    let title: String
    let icon: String
    let tint: Color
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(isSelected ? Color.white : tint)
                    .frame(width: 18, alignment: .center)

                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.92))
                    .lineLimit(1)

                Spacer(minLength: 6)

                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.88) : Color.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6.5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(backgroundColor)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var backgroundColor: Color {
        if isSelected {
            return Color.accentColor
        }
        return isHovered ? Color.primary.opacity(0.065) : Color.clear
    }
}
