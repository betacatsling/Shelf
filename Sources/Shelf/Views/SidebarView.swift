import SwiftUI

struct SidebarView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(AppUpdater.self) private var updater
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selectionNamespace

    private var lang: AppLanguage { store.language }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    sectionHeader(lang.tr("分类", "Library"))
                    destinationRow(.all)
                    ForEach(MediaCategory.allCases) { category in
                        destinationRow(.category(category))
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    sectionHeader(lang.tr("精选", "Collections"))
                    destinationRow(.fiveStar)
                    destinationRow(.timeline)
                }
            }
            .animation(reduceMotion ? nil : ShelfMotion.control, value: store.selectedDestination)
            .padding(.horizontal, 10)
            .padding(.top, 12)
            .padding(.bottom, 16)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                if store.hasSampleItems {
                    ShelfHairline()

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
                                variant: .subtle,
                                horizontalPadding: 7,
                                verticalPadding: 2.5,
                                cornerRadius: 5
                            )
                        )
                        .font(.system(size: 10.5, weight: .medium))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                ShelfHairline()

                HStack(spacing: 6) {
                    CompactLanguageToggle(language: lang, onToggle: { store.toggleLanguage() })
                    SidebarUpdateButton(updater: updater, language: lang)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .frame(height: ShelfTheme.bottomBarHeight)
                .animation(reduceMotion ? nil : ShelfMotion.control, value: updater.availableUpdate != nil)
            }
            .animation(reduceMotion ? nil : ShelfMotion.gentle, value: store.hasSampleItems)
            .background(.ultraThinMaterial.opacity(0.01))
        }
    }

    private func destinationRow(_ destination: SidebarDestination) -> some View {
        SidebarRowButton(
            title: destination.title(in: lang),
            icon: destination.systemImage,
            tint: destination.tintColor,
            count: store.count(for: destination),
            isSelected: store.selectedDestination == destination,
            selectionNamespace: selectionNamespace
        ) {
            store.selectDestination(destination)
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(lang == .en ? 0.5 : 0.2)
            .foregroundStyle(Color.primary.opacity(0.42))
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
    }
}

private struct SidebarRowButton: View {
    let title: String
    let icon: String
    let tint: Color
    let count: Int
    let isSelected: Bool
    let selectionNamespace: Namespace.ID
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        let isDark = colorScheme == .dark
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 13.5, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(tint)
                    .opacity(isSelected ? 1.0 : (isHovered ? 0.95 : 0.85))
                    .frame(width: 18, alignment: .center)

                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(isHovered ? 0.95 : 0.84))
                    .lineLimit(1)

                Spacer(minLength: 6)

                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(isSelected ? Color.primary.opacity(0.75) : Color.primary.opacity(0.40))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6.5)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                        .fill(tint.opacity(isDark ? 0.20 : 0.13))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                                .strokeBorder(tint.opacity(isDark ? 0.30 : 0.22), lineWidth: 0.7)
                        )
                        .matchedGeometryEffect(id: "sidebarActive", in: selectionNamespace)
                } else if isHovered {
                    RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                        .fill(Color.primary.opacity(isDark ? 0.065 : 0.048))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 7.5, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : ShelfMotion.micro, value: isHovered)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct CompactLanguageToggle: View {
    let language: AppLanguage
    let onToggle: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var pillNamespace
    @State private var isHovered = false

    var body: some View {
        let isDark = colorScheme == .dark
        Button(action: onToggle) {
            HStack(spacing: 1) {
                langPill(title: "中", isSelected: language == .zh)
                langPill(title: "EN", isSelected: language == .en)
            }
            .padding(2)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(isHovered ? (isDark ? 0.10 : 0.075) : (isDark ? 0.07 : 0.05)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(isHovered ? 0.14 : 0.08), lineWidth: 0.6)
            )
            .animation(reduceMotion ? nil : ShelfMotion.control, value: language)
            .animation(reduceMotion ? nil : ShelfMotion.micro, value: isHovered)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(language.tr("切换为 English (⌘L)", "Switch to 中文 (⌘L)"))
    }

    private func langPill(title: String, isSelected: Bool) -> some View {
        let isDark = colorScheme == .dark
        return Text(title)
            .font(.system(size: 10, weight: isSelected ? .semibold : .medium, design: .rounded))
            .foregroundStyle(isSelected ? Color.primary : Color.secondary.opacity(0.75))
            .padding(.horizontal, 5.5)
            .padding(.vertical, 2)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .shadow(color: .black.opacity(isDark ? 0.24 : 0.08), radius: 1.5, x: 0, y: 0.5)
                        .matchedGeometryEffect(id: "langThumb", in: pillNamespace)
                }
            }
    }
}
