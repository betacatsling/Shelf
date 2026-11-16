import SwiftUI

struct SidebarView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(AppUpdater.self) private var updater
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                    CompactLanguageToggle(language: lang, onToggle: { store.toggleLanguage() })
                    SidebarUpdateButton(updater: updater, language: lang)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .frame(height: 30)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: updater.availableUpdate != nil)
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
    let language: AppLanguage
    let onToggle: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onToggle) {
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

private struct SidebarUpdateButton: View {
    let updater: AppUpdater
    let language: AppLanguage

    @Environment(\.openURL) private var openURL
    @State private var isHovered = false

    var body: some View {
        if let update = updater.availableUpdate {
            Button {
                handleTap()
            } label: {
                labelView(for: updater.phase)
                    .padding(.horizontal, 7.5)
                    .padding(.vertical, 3.5)
                    .foregroundStyle(Color.white)
                    .background(pillBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.white.opacity(isHovered ? 0.34 : 0.22), lineWidth: 0.6)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .help(helpText(for: update))
            .contextMenu {
                switch updater.phase {
                case .available(let candidate), .failed(let candidate, _):
                    Button(language.tr("立即更新至 \(candidate.displayTag)", "Update to \(candidate.displayTag)")) {
                        updater.performUpdate()
                    }
                case .downloading:
                    Button(language.tr("取消下载", "Cancel Download")) {
                        updater.cancelDownload()
                    }
                case .idle, .checking, .installing:
                    EmptyView()
                }

                Button(language.tr("查看 GitHub 发布说明…", "View Release Notes on GitHub…")) {
                    openURL(update.releasePageURL)
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.94)))
        }
    }

    private func handleTap() {
        switch updater.phase {
        case .available, .failed:
            updater.performUpdate()
        case .idle, .checking, .downloading, .installing:
            break
        }
    }

    @ViewBuilder
    private func labelView(for phase: AppUpdater.Phase) -> some View {
        switch phase {
        case .available(let update):
            ViewThatFits(in: .horizontal) {
                pillContent(icon: "arrow.down.circle.fill", text: language.tr("更新 \(update.displayTag)", "Update \(update.displayTag)"))
                pillContent(icon: "arrow.down.circle.fill", text: update.displayTag)
                pillContent(icon: "arrow.down.circle.fill", text: language.tr("更新", "Update"))
            }

        case .downloading(_, let progress):
            HStack(spacing: 4.5) {
                ProgressView()
                    .controlSize(.mini)
                    .environment(\.colorScheme, .dark)
                    .scaleEffect(0.68)
                    .frame(width: 11, height: 11)

                if let progress {
                    Text("\(Int((progress * 100).rounded()))%")
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                } else {
                    Text(language.tr("下载中…", "Downloading…"))
                        .font(.system(size: 10.5, weight: .semibold))
                        .lineLimit(1)
                }
            }

        case .installing:
            HStack(spacing: 4.5) {
                ProgressView()
                    .controlSize(.mini)
                    .environment(\.colorScheme, .dark)
                    .scaleEffect(0.68)
                    .frame(width: 11, height: 11)

                ViewThatFits(in: .horizontal) {
                    Text(language.tr("正在更新…", "Updating…"))
                        .font(.system(size: 10.5, weight: .semibold))
                        .lineLimit(1)
                    Text(language.tr("更新中", "Updating"))
                        .font(.system(size: 10.5, weight: .semibold))
                        .lineLimit(1)
                }
            }

        case .failed(let update, _):
            ViewThatFits(in: .horizontal) {
                pillContent(icon: "exclamationmark.arrow.triangle.2.circlepath", text: language.tr("重试 \(update.displayTag)", "Retry \(update.displayTag)"))
                pillContent(icon: "exclamationmark.arrow.triangle.2.circlepath", text: language.tr("重试", "Retry"))
            }

        case .idle, .checking:
            EmptyView()
        }
    }

    private func pillContent(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10.5, weight: .semibold))
            Text(text)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var pillBackground: some View {
        switch updater.phase {
        case .downloading(_, let progress):
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Color.accentColor.opacity(0.58)
                    if let progress {
                        Color.accentColor
                            .frame(width: proxy.size.width * min(max(progress, 0), 1))
                    }
                }
            }
        case .failed:
            Color(red: 0.90, green: 0.35, blue: 0.28)
                .opacity(isHovered ? 0.90 : 1.0)
        case .available, .installing:
            Color.accentColor
                .opacity(isHovered ? 0.88 : 1.0)
        case .idle, .checking:
            Color.clear
        }
    }

    private func helpText(for update: AvailableUpdate) -> String {
        switch updater.phase {
        case .available:
            return language.tr(
                "发现新版本 \(update.displayTag)（当前 v\(updater.currentVersion.description)），点击一键更新",
                "New version \(update.displayTag) available (current v\(updater.currentVersion.description)). Click to update."
            )
        case .downloading:
            return language.tr(
                "正在下载 \(update.displayTag)…（右键可取消）",
                "Downloading \(update.displayTag)… (Right-click to cancel)"
            )
        case .installing:
            return language.tr(
                "正在安装 \(update.displayTag) 并准备重启…",
                "Installing \(update.displayTag) and preparing to relaunch…"
            )
        case .failed(_, let message):
            return language.tr(
                "更新失败：\(message)。点击重试",
                "Update failed: \(message). Click to retry."
            )
        case .idle, .checking:
            return ""
        }
    }
}
