import SwiftUI

struct ShelfBottomStatusBar: View {
    let countText: String
    let isTimeline: Bool
    let language: AppLanguage
    @Binding var posterScale: Double
    @Binding var draggedPosterScale: Double?
    @Binding var timelineZoom: Double
    @Binding var draggedTimelineZoom: Double?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 12) {
            Text(countText)
                .font(.system(size: 11.5, weight: .regular))
                .monospacedDigit()
                .foregroundStyle(.secondary.opacity(0.88))

            Spacer()

            HStack(spacing: 4) {
                ZoomStepperButton(
                    systemName: "minus.magnifyingglass",
                    helpText: isTimeline
                        ? language.tr("拉远时间轴 (⌘-)", "Zoom out timeline (⌘-)")
                        : language.tr("缩小海报 (⌘-)", "Zoom out (⌘-)")
                ) {
                    if isTimeline {
                        timelineZoom = TimelineZoomConfig.zoomOut(from: timelineZoom)
                    } else {
                        posterScale = PosterScaleConfig.zoomOut(from: posterScale)
                    }
                }

                if isTimeline {
                    Slider(
                        value: Binding(
                            get: { draggedTimelineZoom ?? timelineZoom },
                            set: { value in
                                if draggedTimelineZoom != nil { draggedTimelineZoom = value }
                                else { timelineZoom = value }
                            }
                        ),
                        in: TimelineZoomConfig.minZoom...TimelineZoomConfig.maxZoom,
                        onEditingChanged: { editing in
                            if editing {
                                draggedTimelineZoom = timelineZoom
                            } else if let value = draggedTimelineZoom {
                                timelineZoom = value
                                draggedTimelineZoom = nil
                            }
                        }
                    )
                    .frame(width: 94)
                    .controlSize(.small)
                    .help(language.tr("拖动调整时间轴缩放", "Adjust timeline zoom"))
                } else {
                    Slider(
                        value: Binding(
                            get: { draggedPosterScale ?? posterScale },
                            set: { value in
                                if draggedPosterScale != nil { draggedPosterScale = value }
                                else { posterScale = value }
                            }
                        ),
                        in: PosterScaleConfig.minScale...PosterScaleConfig.maxScale,
                        onEditingChanged: { editing in
                            if editing {
                                draggedPosterScale = posterScale
                            } else if let value = draggedPosterScale {
                                posterScale = value
                                draggedPosterScale = nil
                            }
                        }
                    )
                    .frame(width: 94)
                    .controlSize(.small)
                    .help(language.tr("拖动调整海报尺寸", "Adjust poster size"))
                }

                ZoomStepperButton(
                    systemName: "plus.magnifyingglass",
                    helpText: isTimeline
                        ? language.tr("拉近时间轴 (⌘+)", "Zoom in timeline (⌘+)")
                        : language.tr("放大海报 (⌘+)", "Zoom in (⌘+)")
                ) {
                    if isTimeline {
                        timelineZoom = TimelineZoomConfig.zoomIn(from: timelineZoom)
                    } else {
                        posterScale = PosterScaleConfig.zoomIn(from: posterScale)
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .frame(height: ShelfTheme.bottomBarHeight)
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(reduceMotion ? nil : ShelfMotion.gentle, value: isTimeline)
    }
}

private struct ZoomStepperButton: View {
    let systemName: String
    let helpText: String
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isHovered ? Color.primary : Color.secondary)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isHovered ? Color.primary.opacity(0.08) : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : ShelfMotion.micro, value: isHovered)
        .onHover { isHovered = $0 }
        .help(helpText)
    }
}
