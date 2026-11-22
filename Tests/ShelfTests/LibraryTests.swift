import Foundation
import Testing
@testable import Shelf

struct LibraryTests {
    @MainActor
    @Test func testQuickFindRanksTitlesBeforeNotesAndRefreshesAfterEdits() async {
        let then = Date(timeIntervalSince1970: 100)
        let prefix = MediaItem(title: "星海", titleEN: "Galaxy Archive", category: .game,
                               status: .active, updatedAt: then)
        let tiedPrefix = MediaItem(title: "Galaxy Two", category: .novel, status: .active, updatedAt: then)
        let substring = MediaItem(title: "The Galaxy", category: .video, status: .active,
                                  updatedAt: then + 10)
        let notesOnly = MediaItem(title: "A Record", category: .video, status: .completed,
                                  notes: "galaxy", updatedAt: then + 20)
        let store = LibraryStore(previewItems: [notesOnly, prefix, tiedPrefix, substring])

        #expect(store.topQuickFindItems(matching: " galaxy ", limit: 3).map(\.id)
                == [prefix.id, tiedPrefix.id, substring.id])
        #expect(store.topQuickFindItems(matching: "galaxy", limit: 64).map(\.id)
                == [prefix.id, tiedPrefix.id, substring.id, notesOnly.id])

        let stale = store.quickFindRequest(matching: "galaxy")
        store.updateNotes(for: notesOnly.id, notes: "updated")
        #expect(await store.backgroundQuickFind(for: stale) == nil)
        #expect(await store.backgroundQuickFind(for: store.quickFindRequest(matching: "galaxy"))?.map(\.id)
                == [prefix.id, tiedPrefix.id, substring.id])
        #expect(store.topQuickFindItems(matching: "galaxy", limit: 64).map(\.id)
                == [prefix.id, tiedPrefix.id, substring.id])
    }

    @MainActor
    @Test func testTagUsageCountsDistinctItemsAndTracksCatalogEdits() {
        let first = MediaItem(title: "First", category: .game, status: .active,
                              tags: ["Collection", "Straße"], rating: 5)
        let second = MediaItem(title: "Second", category: .novel, status: .active,
                               tags: ["STRASSE", "Movie"])
        let store = LibraryStore(previewItems: [first, second])
        store.setTagParent("Straße", parent: "Collection")
        #expect(store.usageCount(forTag: "Collection", includeDescendants: true) == 2)
        #expect(store.usageCount(forTag: "STRASSE", in: .fiveStar) == 1)
        #expect(store.usageCount(forTag: "电影") == 1)
        store.subtagFilter = "Collection"
        #expect(store.projection().count == 2)

        store.updateRating(for: second.id, rating: 5)
        #expect(store.usageCount(forTag: "Collection", in: .fiveStar, includeDescendants: true) == 2)
        _ = store.renameTag(from: "Straße", to: "Child")
        #expect(store.usageCount(forTag: "STRASSE") == 0)
        #expect(store.usageCount(forTag: "Child") == 2)

        store.updateTags(for: second.id, tags: [])
        #expect(store.totalUntaggedCount == 1)
        store.deleteTag("Collection")
        #expect(store.totalUntaggedCount == 2)
        let added = store.addItem(MediaItem(title: "New", category: .game, status: .backlog, tags: ["Movie"]))
        #expect(store.usageCount(forTag: "电影", in: .category(.game)) == 1)
        store.deleteItem(id: added.id)
        #expect(store.usageCount(forTag: "Movie") == 0)
    }

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
    @Test func testLegacySubtagMigrationAndDualEncoding() throws {
        let id = UUID()
        let legacyJSON = """
        [
          {
            "id": "\(id.uuidString)",
            "title": "Blue Prince",
            "category": "game",
            "status": "active",
            "subtag": "Steam",
            "createdAt": "2026-11-15T10:00:00Z",
            "updatedAt": "2026-11-15T10:00:00Z"
          }
        ]
        """
        let fixture = try temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try Data(legacyJSON.utf8).write(to: fixture.url)

        let decoded = try LibraryFile.read(from: fixture.url)
        let first = try #require(decoded.first)
        #expect(first.tags == ["Steam"])
        #expect(first.subtag == "Steam")

        var updated = first
        updated.tags = ["Steam", "独立游戏"]
        try LibraryFile.write([updated], to: fixture.url, formatted: true)

        let rawArray = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.url)) as? [[String: Any]])
        let rawItem = try #require(rawArray.first)
        #expect((rawItem["tags"] as? [String]) == ["Steam", "独立游戏"])
        #expect((rawItem["subtag"] as? String) == "Steam")
    }

    @MainActor
    @Test func testMultiTagFilteringAndBilingualSearchAcrossDestinations() {
        let game = MediaItem(
            title: "蓝途王子",
            titleEN: "Blue Prince",
            category: .game,
            status: .active,
            tags: ["Steam", "解谜"],
            rating: 5
        )
        let novel = MediaItem(
            title: "三体",
            titleEN: "The Three-Body Problem",
            category: .novel,
            status: .completed,
            tags: ["科幻", "解谜"],
            rating: 5
        )
        let video = MediaItem(
            title: "星际穿越",
            titleEN: "Interstellar",
            category: .video,
            status: .completed,
            tags: ["电影", "科幻"],
            rating: 4
        )
        let store = LibraryStore(previewItems: [game, novel, video], language: .en)

        store.selectDestination(.all)
        var result = store.projection()
        #expect(Set(result.subtags) == ["Steam", "解谜", "科幻", "电影"])

        store.subtagFilter = "解谜"
        result = store.projection()
        #expect(Set(result.sections.flatMap(\.items).map(\.id)) == [game.id, novel.id])

        store.selectDestination(.fiveStar)
        result = store.projection()
        #expect(Set(result.sections.flatMap(\.items).map(\.id)) == [game.id, novel.id])
        #expect(Set(result.subtags) == ["Steam", "解谜", "科幻"])

        store.subtagFilter = "科幻"
        #expect(store.projection().sections.flatMap(\.items).map(\.id) == [novel.id])

        store.subtagFilter = nil
        store.selectDestination(.all)
        store.searchText = "sci-fi"
        result = store.projection()
        #expect(Set(result.sections.flatMap(\.items).map(\.id)) == [novel.id, video.id])
    }

    @MainActor
    @Test func testTagCatalogAddRenameMergeDeleteAndPersistence() async throws {
        let fixture = try temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let game1 = MediaItem(title: "Game One", category: .game, status: .active, tags: ["Steam", "解谜"])
        let game2 = MediaItem(title: "Game Two", category: .game, status: .backlog, tags: ["PS5", "解谜", "CRPG"])
        try LibraryFile.write([game1, game2], to: fixture.url)

        let store = LibraryStore(storageURL: fixture.url, language: .zh)
        try await waitUntilLoaded(store)
        #expect(store.isReady)

        // Add custom unused tag
        let added = store.addTag("独立佳作")
        #expect(added == "独立佳作")
        #expect(store.usageCount(forTag: "独立佳作") == 0)
        #expect(store.availableTags(prioritizing: .game).contains("独立佳作"))

        // Rename tag while it is an active filter
        store.subtagFilter = "解谜"
        let renamed = store.renameTag(from: "解谜", to: "推理解谜")
        #expect(renamed == "推理解谜")
        #expect(store.subtagFilter == "推理解谜")
        #expect(store.item(withID: game1.id)?.tags == ["Steam", "推理解谜"])
        #expect(store.item(withID: game2.id)?.tags == ["PS5", "推理解谜", "CRPG"])

        // Merge tag into an existing tag
        let merged = store.renameTag(from: "推理解谜", to: "CRPG")
        #expect(merged == "CRPG")
        #expect(store.subtagFilter == "CRPG")
        #expect(store.item(withID: game1.id)?.tags == ["Steam", "CRPG"])
        #expect(store.item(withID: game2.id)?.tags == ["PS5", "CRPG"])

        // Delete a default starter tag ("PS5") and verify persistence across reload
        store.deleteTag("PS5")
        #expect(store.item(withID: game2.id)?.tags == ["CRPG"])
        #expect(!store.managedTags.contains("PS5"))
        try store.flushPendingChanges()

        let reloaded = LibraryStore(storageURL: fixture.url, language: .zh)
        try await waitUntilLoaded(reloaded)
        #expect(!reloaded.managedTags.contains("PS5"))
        #expect(reloaded.managedTags.contains("独立佳作"))
        #expect(reloaded.item(withID: game2.id)?.tags == ["CRPG"])
    }

    @MainActor
    @Test func testTagTokenAndHashTagSearch() {
        let puzzleSteam = MediaItem(
            title: "蓝途王子",
            titleEN: "Blue Prince",
            category: .game,
            status: .active,
            tags: ["Steam", "解谜"],
            notes: "像在读一本精巧的小说"
        )
        let crpgSteam = MediaItem(
            title: "博德之门 3",
            titleEN: "Baldur's Gate 3",
            category: .game,
            status: .active,
            tags: ["Steam", "CRPG"]
        )
        let sciFiNovel = MediaItem(
            title: "三体",
            titleEN: "The Three-Body Problem",
            category: .novel,
            status: .completed,
            tags: ["小说", "科幻"]
        )
        let store = LibraryStore(previewItems: [puzzleSteam, crpgSteam, sciFiNovel], language: .zh)

        // Multi-tag token AND filtering
        store.toggleSearchTag("Steam")
        #expect(store.searchTokens == [SearchTagToken(tag: "Steam")])
        #expect(Set(store.projection().sections.flatMap(\.items).map(\.id)) == [puzzleSteam.id, crpgSteam.id])
        #expect(store.projection().tagCounts["Steam"] == 2)
        #expect(store.projection().tagCounts["解谜"] == 1)

        store.toggleSearchTag("解谜")
        #expect(store.searchTokens == [SearchTagToken(tag: "Steam"), SearchTagToken(tag: "解谜")])
        #expect(store.projection().sections.flatMap(\.items).map(\.id) == [puzzleSteam.id])

        // Renaming and deleting one of multiple active searchTokens
        let renamed = store.renameTag(from: "解谜", to: "推理解谜")
        #expect(renamed == "推理解谜")
        #expect(store.searchTokens == [SearchTagToken(tag: "Steam"), SearchTagToken(tag: "推理解谜")])
        store.deleteTag("Steam")
        #expect(store.searchTokens == [SearchTagToken(tag: "推理解谜")])
        #expect(store.projection().sections.flatMap(\.items).map(\.id) == [puzzleSteam.id])

        // #小说 filters tags only, not notes containing "小说"
        store.clearSearch()
        #expect(store.searchTokens.isEmpty)
        store.searchText = "#小说"
        #expect(store.projection().sections.flatMap(\.items).map(\.id) == [sciFiNovel.id])

        // Restore Steam on puzzleSteam & crpgSteam isn't needed if testing remaining tags, or use fresh tag on puzzleSteam:
        store.addTag("Steam")
        store.updateTags(for: puzzleSteam.id, tags: ["Steam", "推理解谜"])
        store.updateTags(for: crpgSteam.id, tags: ["Steam", "CRPG"])

        // Combined #Steam 蓝途 tag + title search
        store.searchText = "#Steam 蓝途"
        #expect(store.projection().sections.flatMap(\.items).map(\.id) == [puzzleSteam.id])

        // Bare "#" keeps all items visible
        store.searchText = "#"
        let bareHashProjection = store.projection()
        #expect(bareHashProjection.count == 3)
        #expect(!bareHashProjection.showStatusBadges)

        // commitTypedHashTags converts #sci-fi into canonical SearchTagToken while keeping free text
        store.searchText = "#sci-fi 三体"
        store.commitTypedHashTags()
        #expect(store.searchTokens == [SearchTagToken(tag: "科幻")])
        #expect(store.searchText == "三体")
        #expect(store.projection().sections.flatMap(\.items).map(\.id) == [sciFiNovel.id])
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

    @MainActor
    @Test func testHierarchicalTagsParentFilteringUntaggedAndMigration() async throws {
        let fixture = try temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let steamAndSwitch = MediaItem(
            title: "双平台游戏",
            category: .game,
            status: .active,
            tags: ["Steam", "Switch"]
        )
        let crpgSteam = MediaItem(
            title: "博德之门 3",
            category: .game,
            status: .active,
            tags: ["Steam", "CRPG"]
        )
        let untagged = MediaItem(
            title: "未标记作品",
            category: .novel,
            status: .backlog,
            tags: []
        )
        try LibraryFile.write([steamAndSwitch, crpgSteam, untagged], to: fixture.url)

        // 1. Legacy v1 flat tags.json migrates automatically to v3 categories + nodes
        let tagsURL = fixture.directory.appendingPathComponent("tags.json")
        let legacyTags = ["Steam", "Switch", "小说", "独立佳作"]
        try JSONEncoder().encode(legacyTags).write(to: tagsURL)

        let store = LibraryStore(storageURL: fixture.url, language: .zh)
        try await waitUntilLoaded(store)
        #expect(store.isReady)
        #expect(store.tagCategories.contains("平台"))
        #expect(store.tagCategories.contains("体裁"))
        // Categories are NOT assignable TagNodes
        #expect(!store.tagExists("平台"))
        #expect(!store.tagExists("体裁"))
        #expect(store.tagNodes.first(where: { $0.name == "Steam" })?.category == "平台")
        #expect(store.tagNodes.first(where: { $0.name == "Switch" })?.category == "平台")
        #expect(store.tagNodes.first(where: { $0.name == "小说" })?.category == "体裁")
        #expect(store.tagNodes.first(where: { $0.name == "独立佳作" })?.category == nil)
        #expect(store.tagNodes.first(where: { $0.name == "CRPG" })?.category == nil)

        // Ensure flushing writes v3 TagCatalogPayload
        store.addTag("测试暂存")
        store.deleteTag("测试暂存")
        try store.flushPendingChanges()
        let payload = try JSONDecoder().decode(TagCatalogPayload.self, from: Data(contentsOf: tagsURL))
        #expect(payload.version == 3)
        #expect(payload.categories.contains("平台"))
        #expect(payload.nodes.first(where: { $0.name == "Steam" })?.category == "平台")

        // 2. Parent tag filtering matches descendant tags & counts multi-platform items once
        store.addTag("主机", category: "平台")
        store.setTagParent("Switch", parent: "主机")
        #expect(store.usageCount(forTag: "主机", includeDescendants: true) == 1)
        store.selectSingleTagFilter("主机")
        #expect(store.projection().sections.flatMap(\.items).map(\.id) == [steamAndSwitch.id])

        // 3. refineTagFilter narrows active ancestor "主机" -> "Switch", and intersects unrelated "Steam"
        store.refineTagFilter(with: "Switch")
        #expect(store.searchTokens == [SearchTagToken(tag: "Switch")])
        store.refineTagFilter(with: "Steam")
        #expect(store.searchTokens == [SearchTagToken(tag: "Switch"), SearchTagToken(tag: "Steam")])
        #expect(store.projection().sections.flatMap(\.items).map(\.id) == [steamAndSwitch.id])

        // 4. Untagged ("无标签") filter and projection.untaggedCount
        store.clearSearch()
        #expect(store.projection().untaggedCount == 1)
        store.selectUntaggedFilter()
        #expect(store.filterUntaggedOnly)
        #expect(store.projection().sections.flatMap(\.items).map(\.id) == [untagged.id])

        // 5. Cycle prevention, nesting, parent rename propagation, and cascade delete
        store.setTagParent("主机", parent: "Switch")
        #expect(store.tagNodes.first(where: { $0.name == "主机" })?.parent == nil)

        store.addTag("复古主机", category: "平台")
        store.addTag("GBA", parent: "复古主机")
        #expect(store.tagNodes.first(where: { $0.name == "GBA" })?.category == "平台")
        #expect(store.tagAncestors(of: "GBA") == ["复古主机"])

        let gbaItem = store.addItem(MediaItem(title: "黄金太阳", category: .game, status: .completed, tags: ["GBA"]))
        #expect(store.usageCount(forTag: "复古主机", includeDescendants: true) == 1)

        let renamedParent = store.renameTag(from: "复古主机", to: "掌机与复古")
        #expect(renamedParent == "掌机与复古")
        #expect(store.tagNodes.first(where: { $0.name == "GBA" })?.parent == "掌机与复古")
        #expect(store.tagAncestors(of: "GBA") == ["掌机与复古"])

        store.deleteTag("掌机与复古")
        #expect(!store.tagExists("掌机与复古"))
        #expect(!store.tagExists("GBA"))
        #expect(store.item(withID: gbaItem.id)?.tags.isEmpty == true)

        // 6. Tag category add, rename, move, and delete (moves tags to uncategorized without removing from items)
        store.addTagCategory("风格")
        #expect(store.tagCategories.contains("风格"))
        store.setTagCategory("CRPG", category: "风格")
        #expect(store.tagNodes.first(where: { $0.name == "CRPG" })?.category == "风格")

        store.renameTagCategory(from: "风格", to: "玩法流派")
        #expect(!store.tagCategories.contains("风格"))
        #expect(store.tagCategories.contains("玩法流派"))
        #expect(store.tagNodes.first(where: { $0.name == "CRPG" })?.category == "玩法流派")

        store.deleteTagCategory("玩法流派")
        #expect(!store.tagCategories.contains("玩法流派"))
        #expect(store.tagNodes.first(where: { $0.name == "CRPG" })?.category == nil)
        #expect(store.item(withID: crpgSteam.id)?.hasTag("CRPG") == true)
    }

    @MainActor
    @Test func testV2TagCatalogMigrationPromotesStarterGroupsToCategories() async throws {
        let fixture = try temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let game = MediaItem(title: "Test", category: .game, status: .active, tags: ["Steam"])
        try LibraryFile.write([game], to: fixture.url)

        let v2Payload = TagCatalogPayload(
            version: 2,
            categories: [],
            nodes: [
                TagNode(name: "平台", parent: nil),
                TagNode(name: "Steam", parent: "平台"),
                TagNode(name: "独立佳作", parent: nil)
            ]
        )
        let tagsURL = fixture.directory.appendingPathComponent("tags.json")
        try JSONEncoder().encode(v2Payload).write(to: tagsURL)

        let store = LibraryStore(storageURL: fixture.url, language: .zh)
        try await waitUntilLoaded(store)
        #expect(store.tagCategories == ["平台"])
        #expect(!store.tagExists("平台"))
        #expect(store.tagNodes.first(where: { $0.name == "Steam" })?.category == "平台")
        #expect(store.tagNodes.first(where: { $0.name == "Steam" })?.parent == nil)
        #expect(store.tagNodes.first(where: { $0.name == "独立佳作" })?.category == nil)
    }

    @MainActor
    @Test func testCorruptedTagsFileIsPreservedOnStartupAndFlush() async throws {
        let fixture = try temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let item = MediaItem(title: "Keep Me", category: .game, status: .active)
        try LibraryFile.write([item], to: fixture.url)
        let tagsURL = fixture.directory.appendingPathComponent("tags.json")
        let corrupted = Data("{not valid tags json".utf8)
        try corrupted.write(to: tagsURL)

        let store = LibraryStore(storageURL: fixture.url, language: .en)
        try await waitUntilLoaded(store)
        store.updateNotes(for: item.id, notes: "Updated notes")
        try store.flushPendingChanges()

        #expect(try Data(contentsOf: tagsURL) == corrupted)
    }

    @MainActor
    @Test func testCaseFoldingTagHierarchyAndCanonicalRename() {
        let item = MediaItem(title: "Item", category: .novel, status: .active, tags: ["Straße", "CustomTag"])
        let store = LibraryStore(previewItems: [item], language: .en)
        _ = store.addTag("Child", parent: "STRASSE")

        #expect(TagCatalog.descendants(of: "STRASSE", in: store.tagNodes) == ["Child"])
        #expect(TagCatalog.ancestors(of: "Child", in: store.tagNodes) == ["Straße"])

        let renamed = store.renameTag(from: "CustomTag", to: "Sci-Fi")
        #expect(renamed == "科幻")
        #expect(store.item(withID: item.id)?.tags.contains("科幻") == true)
        #expect(store.item(withID: item.id)?.tags.contains("Sci-Fi") == false)
    }

    @MainActor
    @Test func testQuickFindWhitespaceAndTagPrefixRanking() {
        let titleMatch = MediaItem(title: "三体", category: .novel, status: .active, tags: ["科幻"])
        let notesMatch = MediaItem(title: "另一本书", category: .novel, status: .active, tags: ["科幻"], notes: "提到三体")
        let store = LibraryStore(previewItems: [notesMatch, titleMatch], language: .zh)

        #expect(store.topQuickFindItems(matching: "   ").isEmpty)
        #expect(store.topQuickFindItems(matching: "#科幻 三体").map(\.id) == [titleMatch.id, notesMatch.id])

        store.selectDestination(.category(.game))
        store.addSearchTag("Steam")
        store.searchAllItems("三体")
        #expect(store.selectedDestination == .all)
        #expect(store.searchTokens.isEmpty)
        #expect(store.searchText == "三体")
    }

    @Test func testCoverSearchProviderExtensibility() async {
        struct StubProvider: CoverSearchProvider {
            let bucket: Int
            let candidates: [CoverCandidate]
            func priority(for category: MediaCategory?) -> Int? { bucket }
            func search(keyword: String, category: MediaCategory?, language: AppLanguage) async -> [CoverCandidate] {
                candidates
            }
        }

        let sharedURL = "https://example.com/shared.jpg"
        let pHigh = StubProvider(bucket: 0, candidates: [
            CoverCandidate(id: "a", title: "A", sourceTag: "High", previewURL: sharedURL, fullURL: sharedURL)
        ])
        let pLow = StubProvider(bucket: 1, candidates: [
            CoverCandidate(id: "dup", title: "Dup", sourceTag: "Low", previewURL: sharedURL, fullURL: sharedURL),
            CoverCandidate(id: "b", title: "B", sourceTag: "Low", previewURL: "https://example.com/b.jpg", fullURL: "https://example.com/b.jpg")
        ])

        let service = CoverSearchService(providers: [pLow, pHigh])
        var latest: [CoverCandidate] = []
        await service.searchCoversProgressively(query: "test", category: .game, language: .en) { batch in
            latest = batch
        }
        #expect(latest.map(\.id) == ["a", "b"])
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
