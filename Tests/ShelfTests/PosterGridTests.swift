import AppKit
import QuartzCore
import Testing
@testable import Shelf

@MainActor
struct PosterGridTests {
    @Test func testHoveredPosterEasesBackToRestWhenScrollingStarts() throws {
        let (scroll, grid, coordinator, _) = makeGrid()
        defer { coordinator.detach() }
        let card = try #require(grid.subviews.compactMap { $0 as? PosterCardInteractiveView }.first)
        card.layoutSubtreeIfNeeded()
        let artwork = try #require(card.subviews.first?.layer)
        // Use the same hit test as a pointer over the poster.
        let window = NSWindow(contentRect: scroll.bounds, styleMask: [], backing: .buffered, defer: false)
        window.contentView = scroll
        coordinator.refreshHoverAtCurrentMouseLocation(card.convert(NSPoint(x: 30, y: 30), to: nil))
        #expect(coordinator.activeHoveredView === card)
        card.setHovered(false, animated: false)
        card.setHovered(true, animated: false)
        #expect(!CATransform3DIsIdentity(artwork.transform))

        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        #expect(coordinator.activeHoveredView == nil)
        #expect(CATransform3DIsIdentity(artwork.transform))
        let transition = try #require(artwork.animation(forKey: "transform") as? CABasicAnimation)
        let start = try #require(transition.fromValue as? NSValue)
        #expect(start.caTransform3DValue.m11 > 1)
        #expect(transition.duration > 0)
        #expect(abs(scroll.contentView.bounds.minY) <= 0.5)
    }

    @Test func testHoverStaysSuspendedAcrossGestureEndAndMomentum() async throws {
        let (scroll, _, coordinator, _) = makeGrid()
        defer { coordinator.detach() }
        let center = NotificationCenter.default
        center.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        center.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        // Keep the grid moving for longer than the idle delay after the gesture ends.
        for step in 1...6 {
            try #require(coordinator.isLiveScrolling)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: step * 12))
            center.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
            try await Task.sleep(for: .milliseconds(30))
        }
        try #require(coordinator.isLiveScrolling)
        for _ in 0..<60 where coordinator.isLiveScrolling {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!coordinator.isLiveScrolling)
    }

    @Test func testNewRowsMountBeforeEnteringViewportAndKeepTheirViews() {
        let fixture = makeGrid()
        let (scroll, grid, coordinator, posters) = fixture
        defer { coordinator.detach() }
        let clip = scroll.contentView
        let initial = grid.subviews.compactMap { $0 as? PosterCardInteractiveView }
        #expect(initial.count < 40)
        guard let upcoming = initial.filter({ $0.frame.minY >= clip.bounds.maxY })
            .min(by: { $0.frame.minY < $1.frame.minY }) else {
            Issue.record("No poster row mounted beyond the clip edge")
            return
        }
        let id = upcoming.item?.id
        #expect(upcoming.superview === grid)
        clip.scroll(to: NSPoint(x: 0, y: upcoming.frame.minY - clip.bounds.height + 24))
        scroll.reflectScrolledClipView(clip)
        #expect(upcoming.frame.intersects(clip.bounds))
        #expect(upcoming.superview === grid)
        #expect(upcoming.item?.id == id)

        clip.scroll(to: NSPoint(x: 0, y: grid.bounds.height - clip.bounds.height))
        scroll.reflectScrolledClipView(clip)
        let last = grid.subviews.compactMap { $0 as? PosterCardInteractiveView }
        #expect(last.count < 40)
        #expect(last.contains { $0.item?.id == posters.last?.id && $0.frame.intersects(clip.bounds) })
    }

    @Test func testReservingSpaceForDetailsKeepsCardSizeAndSelectedRow() throws {
        let (scroll, grid, coordinator, posters) = makeGrid()
        defer { coordinator.detach() }
        let clip = scroll.contentView
        clip.scroll(to: NSPoint(x: 0, y: 1400))
        scroll.reflectScrolledClipView(clip)
        let id = posters[23].id
        let card = try #require(grid.subviews.compactMap { $0 as? PosterCardInteractiveView }
            .first { $0.item?.id == id })
        let offset = card.frame.minY - clip.bounds.minY
        let size = card.frame.size
        #expect(card.frame.intersects(clip.bounds))
        coordinator.select(id)

        scroll.setFrameSize(NSSize(width: 519, height: 640))
        scroll.tile()
        let resized = try #require(grid.subviews.compactMap { $0 as? PosterCardInteractiveView }
            .first { $0.item?.id == id })
        #expect(clip.bounds.width < 600)
        #expect(resized.frame.size == size)
        #expect(abs(resized.frame.minY - clip.bounds.minY - offset) <= 1)
    }

    private func makeGrid() -> (NSScrollView, PosterGridView, NativePosterGrid.Coordinator, [LibraryPoster]) {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 840, height: 640))
        scroll.contentView.postsFrameChangedNotifications = true
        let grid = PosterGridView(frame: scroll.bounds)
        scroll.documentView = grid

        let posters = (0..<250).map { index in
            LibraryPoster(MediaItem(title: "Item \(index)", category: .game, status: .active,
                                    coverFileName: "test-cover-\(index).jpg"), language: .en)
        }
        let section = ShelfSectionModel(status: nil, title: "", totalCount: posters.count, items: posters)
        let model = NativePosterGrid(sections: [section], collapsedShelves: [], selectedItemID: nil,
            showStatusBadges: false, posterScale: 1, posterWidthBasis: 840, language: .en, scrollResetToken: 0,
            onSelectItem: { _ in }, onEnsureSelectItem: { _ in }, onDeselectAll: {},
            onDoubleClickEdit: { _ in }, onRequestReplaceCover: { _ in },
            onToggleSectionCollapse: { _ in }, onQuickAddInSection: { _ in },
            onChangeStatus: { _, _ in }, onChangeRating: { _, _ in }, onUpdateCoverFileName: { _, _ in },
            onImportCover: { _, _ in }, onDeleteItem: { _ in }, onShowToast: { _ in })
        let coordinator = model.makeCoordinator()
        coordinator.gridView = grid
        coordinator.scrollView = scroll
        grid.coordinator = coordinator
        coordinator.installScrollObservers(for: scroll)
        coordinator.update(model)
        return (scroll, grid, coordinator, posters)
    }
}
