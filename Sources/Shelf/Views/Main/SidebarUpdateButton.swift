import SwiftUI

struct SidebarUpdateButton: View {
    let updater: AppUpdater
    let language: AppLanguage

    @Environment(\.openURL) private var openURL
    @State private var isHovered = false

    private var isActionable: Bool {
        switch updater.phase {
        case .available, .failed: return true
        case .idle, .checking, .downloading, .installing: return false
        }
    }

    var body: some View {
        if let update = updater.availableUpdate {
            Button {
                if isActionable {
                    updater.performUpdate()
                }
            } label: {
                labelView(for: updater.phase)
                    .padding(.horizontal, 7.5)
                    .padding(.vertical, 3.5)
                    .foregroundStyle(Color.white)
                    .background(pillBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.white.opacity(isHovered && isActionable ? 0.34 : 0.22), lineWidth: 0.6)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { isHovered = isActionable && $0 }
            .onDisappear { isHovered = false }
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
                compactWhiteSpinner
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
                compactWhiteSpinner
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

    private var compactWhiteSpinner: some View {
        ProgressView()
            .controlSize(.mini)
            .environment(\.colorScheme, .dark)
            .scaleEffect(0.68)
            .frame(width: 11, height: 11)
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
            ShelfTheme.destructiveRed
                .opacity(isHovered ? 0.90 : 1.0)
        case .available, .installing:
            Color.accentColor
                .opacity(isHovered && isActionable ? 0.88 : 1.0)
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
