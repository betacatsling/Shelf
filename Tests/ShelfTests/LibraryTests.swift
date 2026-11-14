import Foundation
import Testing
@testable import Shelf

struct LibraryTests {
    @MainActor
    @Test func testSearchKeepsBilingualCountsAndNotesInSync() {
        let titleOnly = MediaItem(title: "甲", titleEN: "Forest THREE", category: .novel,
                                  status: .active, subtag: "轻小说", rating: 5)
        let tagOnly = MediaItem(title: "乙", category: .novel, status: .completed, subtag: "轻小说")
        let notesOnly = MediaItem(title: "丙", category: .novel, status: .active, subtag: "小说")
        let otherCategory = MediaItem(title: "丁", category: .game, status: .active, notes: "Light Novel")
        let store = LibraryStore(previewItems: [titleOnly, tagOnly, notesOnly, otherCategory], language: .en)
        store.selectDestination(.category(.novel))

        store.searchText = "  LIGHT NOVEL  "
        var result = store.projection()
        #expect(result.count == 2)
        #expect(result.statusCounts == [.active: 1, .completed: 1])
        #expect(result.subtags == ["轻小说"])
        #expect(result.showStatusBadges)

        store.updateNotes(for: notesOnly.id, notes: "This is a Light Novel.")
        #expect(store.projection().count == 3)
        store.statusFilter = .single(.active)
        result = store.projection()
        #expect(Set(result.sections.flatMap(\.items).map(\.id)) == [titleOnly.id, notesOnly.id])
        #expect(result.statusCounts == [.active: 2, .completed: 1])

        store.subtagFilter = "小说"
        #expect(store.projection().statusCounts == [.active: 1])
        #expect(Set(store.projection().subtags) == ["小说", "轻小说"])
        store.searchText = "FOREST three"
        #expect(store.projection().count == 0)
        store.subtagFilter = nil
        #expect(store.projection().sections.first?.items.first?.id == titleOnly.id)

        store.selectedItemID = titleOnly.id
        store.selectDestination(.fiveStar)
        #expect(store.selectedItem?.id == titleOnly.id)
        store.updateRating(for: titleOnly.id, rating: 4)
        #expect(store.count(for: .fiveStar) == 0)
        #expect(store.projection().count == 0)
    }

    @MainActor
    @Test func testStaleQueryAndEditorCoverDoNotReplaceNewerState() async {
        let entry = MediaItem(title: "Shelf", category: .game, status: .active, coverFileName: "old.jpg")
        let store = LibraryStore(previewItems: [entry], language: .en)
        store.searchText = "missing"
        let staleSearch = store.projectionRequest
        store.searchText = "Shelf"
        #expect(await store.backgroundProjection(for: staleSearch) == nil)
        #expect(await store.backgroundProjection(for: store.projectionRequest)?.count == 1)

        store.updateCover(for: entry.id, newCoverFileName: "new.jpg")
        var edited = entry
        edited.notes = "Saved from an already open editor"
        store.updateItem(edited, originalCoverFileName: entry.coverFileName)
        #expect(store.item(withID: entry.id)?.coverFileName == "new.jpg")
        #expect(store.item(withID: entry.id)?.notes == edited.notes)
    }

    @MainActor
    @Test func testQuitFlushWinsOverDebouncedEditsAndEarlierWrites() async throws {
        let fixture = try temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let item = MediaItem(title: "Library", category: .game, status: .active)
        try LibraryFile.write([item], to: fixture.url)
        let store = LibraryStore(storageURL: fixture.url, language: .en)
        try await waitUntilLoaded(store)
        #expect(store.isReady)

        store.updateRating(for: item.id, rating: 3)
        try await Task.sleep(for: .milliseconds(160))
        store.updateNotes(for: item.id, notes: "Newest unsaved note")
        store.updateStatus(for: item.id, to: .completed)
        try store.flushPendingChanges()

        let saved = try #require(LibraryFile.read(from: fixture.url).first)
        #expect(saved.rating == 3)
        #expect(saved.status == .completed)
        #expect(saved.notes == "Newest unsaved note")

        store.updateNotes(for: item.id, notes: "Edited again")
        try store.flushPendingChanges()
        #expect(try LibraryFile.read(from: fixture.url).first?.notes == "Edited again")
    }

    @MainActor
    @Test func testUnreadableLibraryIsNotOverwrittenOnExit() async throws {
        let fixture = try temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let corrupt = Data("not a valid library".utf8)
        try corrupt.write(to: fixture.url)
        let store = LibraryStore(storageURL: fixture.url, language: .en)
        try await waitUntilLoaded(store)
        #expect(store.loadFailed)
        store.restoreSampleItems()
        try store.flushPendingChanges()
        #expect(try Data(contentsOf: fixture.url) == corrupt)
    }

    @MainActor
    @Test func testFirstLaunchStillCreatesSamples() async throws {
        let fixture = try temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = LibraryStore(storageURL: fixture.url, language: .en)
        try await waitUntilLoaded(store)
        #expect(store.isReady)
        #expect(store.hasSampleItems)
        try store.flushPendingChanges()
        #expect(try LibraryFile.read(from: fixture.url).count > 0)
    }

    private func temporaryLibrary() throws -> (directory: URL, url: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-tests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, directory.appendingPathComponent("library.json"))
    }

    @MainActor
    private func waitUntilLoaded(_ store: LibraryStore) async throws {
        for _ in 0..<200 where store.isLoading {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!store.isLoading)
    }
}
