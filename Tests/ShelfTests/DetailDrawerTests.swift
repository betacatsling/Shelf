import AppKit
import Testing
@testable import Shelf

@MainActor
struct DetailDrawerTests {
    @Test func testRapidSelectionDocksOnlyTheLatestDrawerStateWithReducedMotion() async throws {
        let first = MediaItem(title: "First", category: .game, status: .active)
        let second = MediaItem(title: "Second", category: .video, status: .active)
        let store = LibraryStore(previewItems: [first, second], language: .en)
        let drawer = DetailDrawerClipView(frame: CGRect(x: 0, y: 0, width: DetailDrawer.width, height: 700))
        var docked: [Bool] = []

        func show(_ item: MediaItem?) {
            drawer.update(item: item, initialPosterID: nil, store: store, reduceMotion: true,
                          onReplaceCover: { _ in }, onDockChange: { docked.append($0) })
        }

        show(first)
        show(nil)
        show(second)
        for _ in 0..<20 where docked.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
        #expect(docked == [true])
        #expect(drawer.layer?.sublayerTransform.m41 == 0)
        #expect(drawer.layer?.animationKeys()?.isEmpty != false)

        show(nil)
        for _ in 0..<20 where docked.count < 2 { try await Task.sleep(for: .milliseconds(2)) }
        #expect(docked == [true, false])
        #expect(drawer.layer?.sublayerTransform.m41 == DetailDrawer.width)
    }
}
