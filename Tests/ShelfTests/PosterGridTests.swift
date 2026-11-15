import AppKit
import Testing
@testable import Shelf

@MainActor
struct PosterGridTests {
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
