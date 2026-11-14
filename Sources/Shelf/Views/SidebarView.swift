import SwiftUI

struct SidebarView: View {
    @Environment(LibraryStore.self) private var store

    private var lang: AppLanguage { store.language }

    var body: some View {
        @Bindable var store = store
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
                    sectionHeader(lang.tr("精选", "Collections"))

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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                if store.hasSampleItems {
                    Divider()
                        .opacity(0.45)

                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                        Text(lang.tr("示例数据", "Samples"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(lang.tr("清空", "Clear")) {
                            store.clearSampleItems()
                        }
                        .buttonStyle(
                            ShelfButtonStyle(
                                variant: .secondary,
                                horizontalPadding: 7,
                                verticalPadding: 2.5,
                                cornerRadius: 5
                            )
                        )
                        .font(.system(size: 10.5, weight: .medium))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }

                Divider()

                HStack(spacing: 6) {
                    CompactLanguageToggle(language: $store.language)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .frame(height: 30)
            }
            .background(.ultraThinMaterial.opacity(0.01))
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.primary.opacity(0.48))
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
                        .monospacedDigit()
                        .foregroundStyle(isSelected ? Color.white.opacity(0.90) : Color.primary.opacity(0.48))
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

private struct CompactLanguageToggle: View {
    @Binding var language: AppLanguage
    @State private var isHovered = false

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.16)) {
                language = (language == .zh) ? .en : .zh
            }
        } label: {
            HStack(spacing: 4.5) {
                Image(systemName: "globe")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)

                HStack(spacing: 2) {
                    langPill(title: "中", isSelected: language == .zh)
                    Text("/")
                        .font(.system(size: 9.5, weight: .regular))
                        .foregroundStyle(.tertiary)
                    langPill(title: "EN", isSelected: language == .en)
                }
            }
            .padding(.horizontal, 6.5)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(0.07) : Color.primary.opacity(0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(isHovered ? 0.14 : 0.08), lineWidth: 0.6)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(language.tr("切换为 English (⌘L)", "Switch to 中文 (⌘L)"))
    }

    private func langPill(title: String, isSelected: Bool) -> some View {
        Text(title)
            .font(.system(size: 10.5, weight: isSelected ? .semibold : .regular, design: .rounded))
            .foregroundStyle(isSelected ? Color.primary.opacity(0.92) : Color.secondary.opacity(0.75))
            .padding(.horizontal, 3.5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isSelected ? Color.primary.opacity(0.12) : Color.clear)
            )
    }
}
