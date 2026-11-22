import AppKit
import SwiftUI

enum PosterGridKeyCode {
    static let returnKey: UInt16 = 36
    static let escape: UInt16 = 53
    static let enterKey: UInt16 = 76
    static let leftArrow: UInt16 = 123
    static let rightArrow: UInt16 = 124
    static let downArrow: UInt16 = 125
    static let upArrow: UInt16 = 126
}

/// Aggregates all user-triggered callbacks from the poster grid into one extensible struct.
struct PosterGridActions {
    var onSelectItem: (UUID) -> Void = { _ in }
    var onEnsureSelectItem: (UUID) -> Void = { _ in }
    var onDeselectAll: () -> Void = {}
    var onDoubleClickEdit: (UUID) -> Void = { _ in }
    var onRequestEditTags: (UUID) -> Void = { _ in }
    var onRequestReplaceCover: (UUID) -> Void = { _ in }
    var onToggleSectionCollapse: (TrackingStatus) -> Void = { _ in }
    var onQuickAddInSection: (TrackingStatus) -> Void = { _ in }
    var onChangeStatus: (UUID, TrackingStatus) -> Void = { _, _ in }
    var onChangeRating: (UUID, Int) -> Void = { _, _ in }
    var onUpdateCoverFileName: (UUID, String?) -> Void = { _, _ in }
    var onImportCover: (UUID, CoverSource) -> Void = { _, _ in }
    var onDeleteItem: (UUID) -> Void = { _ in }
    var onShowToast: (String) -> Void = { _ in }
}

struct NativePosterGrid: NSViewRepresentable {
    let sections: [ShelfSectionModel]
    let collapsedShelves: Set<TrackingStatus>
    let selectedItemID: UUID?
    let showStatusBadges: Bool
    let posterScale: Double
    var posterWidthBasis: CGFloat? = nil
    let language: AppLanguage
    let scrollResetToken: Int
    var actions = PosterGridActions()

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        coordinator.reduceMotion = context.environment.accessibilityReduceMotion

        let initialRect = NSRect(x: 0, y: 0, width: 900, height: 640)
        let scrollView = NSScrollView(frame: initialRect)
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.usesPredominantAxisScrolling = true
        scrollView.borderType = .noBorder
        scrollView.contentView.postsFrameChangedNotifications = true

        let grid = PosterGridView(frame: initialRect)
        grid.coordinator = coordinator
        scrollView.documentView = grid

        coordinator.scrollView = scrollView
        coordinator.gridView = grid
        coordinator.installScrollObservers(for: scrollView)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.reduceMotion = context.environment.accessibilityReduceMotion
        context.coordinator.update(self)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.detach()
    }
}
