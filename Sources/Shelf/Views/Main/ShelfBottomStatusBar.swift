import SwiftUI

struct ShelfBottomStatusBar: View {
    let countText: String
    let isTimeline: Bool
    let language: AppLanguage
    @Binding var posterScale: Double
    @Binding var draggedPosterScale: Double?
    @Binding var timelineZoom: Double
    @Binding var draggedTimelineZoom: Double?

    var body: some View {
        HStack(spacing: 12) {
            Text(countText)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Spacer()

            HStack(spacing: 8) {
                Button {
                    if isTimeline {
                        timelineZoom = TimelineZoomConfig.zoomOut(from: timelineZoom)
                    } else {
                        posterScale = PosterScaleConfig.zoomOut(from: posterScale)
                    }
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(
                    isTimeline
                        ? language.tr("拉远时间轴 (⌘-)", "Zoom out timeline (⌘-)")
                        : language.tr("缩小海报 (⌘-)", "Zoom out (⌘-)")
                )

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
                    .frame(width: 96)
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
                    .frame(width: 96)
                    .controlSize(.small)
                    .help(language.tr("拖动调整海报尺寸", "Adjust poster size"))
                }

                Button {
                    if isTimeline {
                        timelineZoom = TimelineZoomConfig.zoomIn(from: timelineZoom)
                    } else {
                        posterScale = PosterScaleConfig.zoomIn(from: posterScale)
                    }
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(
                    isTimeline
                        ? language.tr("拉近时间轴 (⌘+)", "Zoom in timeline (⌘+)")
                        : language.tr("放大海报 (⌘+)", "Zoom in (⌘+)")
                )
            }
        }
        .padding(.horizontal, 18)
        .frame(height: ShelfTheme.bottomBarHeight)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
