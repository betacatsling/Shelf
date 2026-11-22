import Foundation
import Observation

@MainActor
@Observable
final class LibraryStore {
    var language: AppLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: "shelf.language") }
    }
    var timelineCategories: Set<MediaCategory> = {
        guard let raw = UserDefaults.standard.string(forKey: "shelf.timelineCategories") else {
            return Set(MediaCategory.allCases)
        }
        return Set(raw.split(separator: ",").compactMap { MediaCategory(rawValue: String($0)) })
    }() {
        didSet {
            let encoded = MediaCategory.allCases
                .filter { timelineCategories.contains($0) }
                .map(\.rawValue)
                .joined(separator: ",")
            UserDefaults.standard.set(encoded, forKey: "shelf.timelineCategories")
        }
    }
    var selectedDestination: SidebarDestination = .all
    var statusFilter: StatusFilterOption = .allShelves
    var searchTokens: [SearchTagToken] = [] {
        didSet {
            let deduplicated = Self.deduplicateTokens(searchTokens)
            if deduplicated != searchTokens {
                searchTokens = deduplicated
            }
            if !searchTokens.isEmpty && filterUntaggedOnly {
                filterUntaggedOnly = false
            }
        }
    }
    var filterUntaggedOnly: Bool = false {
        didSet {
            if filterUntaggedOnly && !searchTokens.isEmpty {
                searchTokens = []
            }
        }
    }
    var subtagFilter: String? {
        get { searchTokens.first?.tag }
        set {
            let canonical = newValue.map(MediaCategory.canonicalTag) ?? ""
            let next = canonical.isEmpty ? [] : [SearchTagToken(tag: canonical)]
            if searchTokens != next {
                searchTokens = next
            }
        }
    }
    var activeFilterTags: [String] { searchTokens.map(\.tag) }
    var hasActiveTagFilter: Bool { filterUntaggedOnly || !searchTokens.isEmpty }
    var hasActiveFilter: Bool { hasActiveTagFilter || !trimmedSearchText.isEmpty }
    var sortField: LibrarySortField = .updatedAt
    var sortAscending = false
    var searchText = ""
    var isQuickFindPresented = false
    var tagPickerItemID: UUID? = nil
    var isTagWindowKey = false
    var isDetailPopoverPresented = false
    var selectedItemID: UUID? {
        didSet { refreshSelectedItem() }
    }
    private(set) var selectedItem: MediaItem?
    private(set) var tagCategories: [String] = []
    private(set) var tagNodes: [TagNode] = [] {
        didSet { tagTree = TagCatalog.Tree(tagNodes) }
    }
    var managedTags: [String] { tagNodes.map(\.name) }
    private(set) var toastMessage: String?
    private(set) var isLoading = false
    private(set) var loadFailed = false

    private struct Counts: Equatable, Sendable {
        var total = 0
        var categories: [MediaCategory: Int] = [:]
        var fiveStar = 0
        var dated = 0
        var samples = 0

        mutating func include(_ item: MediaItem, delta: Int) {
            total += delta
            categories[item.category, default: 0] += delta
            if item.rating == 5 { fiveStar += delta }
            if item.hasTimelineDates { dated += delta }
            if item.isSample { samples += delta }
        }
    }

    private struct RecordIndex: Sendable {
        var indices: [UUID: Int] = [:]
        var coverReferences: [String: Int] = [:]
        var counts = Counts()

        init(_ items: [MediaItem]) {
            indices.reserveCapacity(items.count)
            for (index, item) in items.enumerated() {
                if indices[item.id] == nil { indices[item.id] = index }
                if let name = item.coverFileName { coverReferences[name, default: 0] += 1 }
                counts.include(item, delta: 1)
            }
        }
    }

    private var counts = Counts()
    private var catalogRevision: UInt64 = 0
    private var sortRevision: UInt64 = 0
    private var notesRevision: UInt64 = 0

    @ObservationIgnored private var records: [MediaItem] = []
    @ObservationIgnored private var indices: [UUID: Int] = [:]
    @ObservationIgnored private var coverReferences: [String: Int] = [:]
    @ObservationIgnored private var query = LibraryQuery()
    @ObservationIgnored private var tagTree = TagCatalog.Tree([])
    @ObservationIgnored private var tagUsage: (byTag: [String: [Int]], untagged: Int)?
    @ObservationIgnored private var quickFindCache: (request: LibraryQuery.QuickFindRequest, limit: Int, items: [MediaItem])?
    @ObservationIgnored private var tagsCatalogCorrupted = false
    private let queryWorker = LibraryQuery.Worker()
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var dirtySince: ContinuousClock.Instant?
    @ObservationIgnored private var revision: UInt64 = 0
    @ObservationIgnored private var savedRevision: UInt64 = 0
    @ObservationIgnored private var writing = false
    @ObservationIgnored private var coversToRemove: [String: UInt64] = [:]
    @ObservationIgnored private var coverImports: [UUID: Task<Void, Never>] = [:]

    private let libraryFile: LibraryFile?

    convenience init() {
        let savedLang = UserDefaults.standard.string(forKey: "shelf.language").flatMap(AppLanguage.init(rawValue:)) ?? .zh
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.init(storageURL: support.appendingPathComponent("Shelf/library.json"), language: savedLang)
    }

    init(storageURL: URL, language: AppLanguage) {
        self.language = language
        let file = LibraryFile(url: storageURL)
        libraryFile = file
        isLoading = true
        Task { [weak self] in
            do {
                let snapshot = try await file.loadSnapshot()
                let initialItems = snapshot.items ?? Self.makeStarterSamples()
                let baseCategories = snapshot.tagCategories ?? TagCatalog.defaultStarterCategories
                let baseNodes = snapshot.tagNodes ?? TagCatalog.defaultStarterNodes
                let prepared = await Task.detached(priority: .userInitiated) {
                    let normalized = TagCatalog.normalize(categories: baseCategories, nodes: baseNodes,
                                                          mergingItemTags: initialItems.flatMap(\.tags))
                    return (normalized, RecordIndex(initialItems))
                }.value
                guard let self else { return }
                let (normalized, recordIndex) = prepared
                tagsCatalogCorrupted = snapshot.tagCatalogCorrupted
                tagCategories = normalized.categories
                tagNodes = normalized.nodes
                replaceRecords(with: initialItems, index: recordIndex)
                isLoading = false
                if snapshot.tagCatalogCorrupted {
                    showToast(language.tr("tags.json 读取失败，已保留原文件未覆盖", "Could not read tags.json; existing file preserved"))
                } else if snapshot.items == nil || snapshot.tagNodes == nil {
                    scheduleSave()
                }
            } catch {
                guard let self else { return }
                print("Failed to read library.json: \(error)")
                loadFailed = true
                isLoading = false
            }
        }
    }

    /// An in-memory library for previews and tests.
    init(previewItems: [MediaItem], language: AppLanguage = .zh) {
        self.language = language
        libraryFile = nil
        let normalized = TagCatalog.normalize(
            categories: TagCatalog.defaultStarterCategories,
            nodes: TagCatalog.defaultStarterNodes,
            mergingItemTags: previewItems.flatMap(\.tags)
        )
        tagCategories = normalized.categories
        tagNodes = normalized.nodes
        replaceRecords(with: previewItems)
    }

    var isReady: Bool { !isLoading && !loadFailed }
    var isEmpty: Bool { counts.total == 0 }
    var hasSampleItems: Bool { counts.samples > 0 }
    var totalUntaggedCount: Int { usageIndex().untagged }

    func item(withID id: UUID) -> MediaItem? {
        indices[id].map { records[$0] }
    }

    func toggleLanguage() {
        language = (language == .zh) ? .en : .zh
    }

    func toggleTimelineCategory(_ category: MediaCategory) {
        if timelineCategories.contains(category) {
            timelineCategories.remove(category)
        } else {
            timelineCategories.insert(category)
        }
    }

    private var activeTagGroupFilters: [TagGroupFilter] {
        activeFilterTags.map { TagGroupFilter(rootTag: $0, matchingTags: expandedTagFamily(for: $0)) }
    }

    func selectDestination(_ destination: SidebarDestination) {
        selectedDestination = destination
        statusFilter = .allShelves
        searchTokens = []
        filterUntaggedOnly = false
        if let item = selectedItem,
           !destination.includes(item)
            || !LibraryQuery.matches(
                item,
                text: trimmedSearchText,
                tagGroups: activeTagGroupFilters,
                untaggedOnly: filterUntaggedOnly
            ) {
            selectedItemID = nil
        }
    }

    /// Reveals an item in the main library view, broadening destination/filters only if currently hidden.
    func revealItem(_ item: MediaItem) {
        if !selectedDestination.includes(item) || (selectedDestination.isTimeline && !item.hasTimelineDates) {
            selectedDestination = .all
        } else if selectedDestination.isTimeline && !timelineCategories.contains(item.category) {
            timelineCategories.insert(item.category)
        }
        if case .single(let status) = statusFilter, status != item.status {
            statusFilter = .allShelves
        }
        if hasActiveFilter {
            let stillVisible = LibraryQuery.matches(
                item,
                text: trimmedSearchText,
                tagGroups: activeTagGroupFilters,
                untaggedOnly: filterUntaggedOnly
            )
            if !stillVisible {
                clearSearch()
            }
        }
        selectedItemID = item.id
    }

    /// Switches to All items with no tag/status restrictions and searches by free text.
    func searchAllItems(_ rawQuery: String) {
        selectedDestination = .all
        statusFilter = .allShelves
        searchTokens = []
        filterUntaggedOnly = false
        searchText = rawQuery.trimmed
    }

    func count(for destination: SidebarDestination) -> Int {
        switch destination {
        case .all: return counts.total
        case .category(let category): return counts.categories[category, default: 0]
        case .fiveStar: return counts.fiveStar
        case .timeline: return counts.dated
        }
    }

    private var trimmedSearchText: String {
        searchText.trimmed
    }

    var projectionRequest: LibraryQuery.Request {
        let text = trimmedSearchText
        return .init(revision: catalogRevision, sortRevision: sortRevision,
                     notesRevision: text.isEmpty ? 0 : notesRevision,
                     options: .init(destination: selectedDestination, status: statusFilter,
                                    tagGroups: activeTagGroupFilters, untaggedOnly: filterUntaggedOnly,
                                    text: text, sortField: sortField,
                                    ascending: sortAscending, language: language))
    }

    var shouldProjectInBackground: Bool { counts.total >= 2_000 }

    func projection() -> LibraryProjection {
        let request = projectionRequest
        return query.project(records, request: request)
    }

    func backgroundProjection(for request: LibraryQuery.Request) async -> LibraryProjection? {
        guard request == projectionRequest else { return nil }
        return await queryWorker.project(records, request: request)
    }

    func narrowingTags(for projection: LibraryProjection, limit: Int = 8) -> [String] {
        LibraryQuery.narrowingTags(
            for: projection,
            catalogNodes: tagNodes,
            activeTokens: searchTokens,
            untaggedOnly: filterUntaggedOnly,
            limit: limit
        )
    }

    func selectSortField(_ field: LibrarySortField) {
        if sortField == field {
            sortAscending.toggle()
        } else {
            sortField = field
            sortAscending = field.defaultAscending
        }
    }

    func quickFindRequest(matching rawQuery: String, limit: Int = 6) -> LibraryQuery.QuickFindRequest {
        .init(text: rawQuery.trimmed, language: language,
              revision: catalogRevision, notesRevision: notesRevision, limit: limit)
    }

    func topQuickFindItems(matching rawQuery: String, limit: Int = 6) -> [MediaItem] {
        let request = quickFindRequest(matching: rawQuery, limit: limit)
        if let cached = quickFindCache, cached.request == request, cached.limit == limit { return cached.items }
        let items = LibraryQuery.quickFind(records, text: request.text, language: request.language, limit: limit)
        quickFindCache = (request, limit, items)
        return items
    }

    func backgroundQuickFind(for request: LibraryQuery.QuickFindRequest) async -> [MediaItem]? {
        guard request == quickFindRequest(matching: request.text, limit: request.limit) else { return nil }
        return await queryWorker.quickFind(records, request: request)
    }

    // MARK: - Tag Tree & Usage Index Helpers (Shared with LibraryTagOperations)

    func expandedTagFamily(for rawTag: String) -> [String] {
        _ = tagNodes
        return tagTree.expandedFamily(for: rawTag)
    }

    func nestedChildCount(for rawTag: String) -> Int {
        _ = tagNodes
        return tagTree.descendants(of: rawTag).count
    }

    func usageCount(
        forTag rawTag: String,
        in destination: SidebarDestination = .all,
        includeDescendants: Bool = false
    ) -> Int {
        let family = includeDescendants ? expandedTagFamily(for: rawTag) : [rawTag]
        let byTag = usageIndex().byTag
        let lists = family.compactMap { byTag[MediaCategory.tagMatchKey($0)] }
        guard let first = lists.first else { return 0 }
        if lists.count == 1 {
            return destination == .all ? first.count : countRecords(in: first, destination: destination)
        }
        var matches = Set(first)
        for list in lists.dropFirst() { matches.formUnion(list) }
        return destination == .all ? matches.count : countRecords(in: matches, destination: destination)
    }

    func resolveTagName(_ rawTag: String) -> String {
        let canonical = MediaCategory.canonicalTag(rawTag)
        guard !canonical.isEmpty else { return "" }
        if let existing = tagNodes.first(where: { MediaCategory.tagsMatch($0.name, canonical) }) {
            return existing.name
        }
        if let existing = records.lazy.flatMap(\.tags).first(where: { MediaCategory.tagsMatch($0, canonical) }) {
            return existing
        }
        return canonical
    }

    func containsUntaggedRecord(in destination: SidebarDestination) -> Bool {
        records.contains { destination.includes($0) && $0.tags.isEmpty }
    }

    func commitTagCatalogChange(categories: [String], nodes: [TagNode], toast: String? = nil) {
        tagsCatalogCorrupted = false
        tagCategories = categories
        tagNodes = nodes
        refreshSelectedItem()
        catalogRevision &+= 1
        scheduleSave()
        if let toast { showToast(toast) }
    }

    func rewriteRecordTags(_ transform: ([String]) -> [String]?) -> Bool {
        var changed = false
        for index in records.indices {
            if let updated = transform(records[index].tags) {
                records[index].tags = updated
                changed = true
            }
        }
        if changed { tagUsage = nil }
        return changed
    }

    static func deduplicateTokens(_ tokens: [SearchTagToken]) -> [SearchTagToken] {
        var seen: Set<String> = []
        var result: [SearchTagToken] = []
        for token in tokens where !token.tag.isEmpty {
            if seen.insert(token.id).inserted {
                result.append(token)
            }
        }
        return result
    }

    func snapshotRecords() -> [MediaItem] {
        records
    }

    func appendImportedItems(_ imported: [MediaItem]) -> Int {
        var ids = Set(indices.keys)
        let newItems = imported.filter { ids.insert($0.id).inserted }
        if !newItems.isEmpty {
            ensureManagedTagsInclude(newItems.flatMap(\.tags))
            replaceRecords(with: records + newItems)
            scheduleSave()
        }
        return newItems.count
    }

    // MARK: - CRUD

    func updateTags(for id: UUID, tags: [String]) {
        guard isReady, let index = indices[id] else { return }
        let normalized = MediaCategory.normalizeTags(tags)
        guard records[index].tags != normalized else { return }
        ensureManagedTagsInclude(normalized)
        var item = records[index]
        item.tags = normalized
        item.isSample = false
        item.updatedAt = Date()
        replaceRecord(at: index, with: item)
    }

    @discardableResult
    func addItem(_ item: MediaItem) -> MediaItem {
        guard isReady else { return item }
        var newItem = item
        if indices[newItem.id] != nil {
            newItem.id = UUID()
        }
        newItem.tags = MediaCategory.normalizeTags(newItem.tags)
        newItem.createdAt = Date()
        newItem.updatedAt = newItem.createdAt
        ensureManagedTagsInclude(newItem.tags)
        var updated = records
        updated.insert(newItem, at: 0)
        replaceRecords(with: updated)
        scheduleSave()
        let quoted = newItem.quotedTitle(in: language)
        showToast(language.tr("已添加\(quoted)", "Added \(quoted)"))
        return newItem
    }

    func updateItem(_ updated: MediaItem, originalCoverFileName: String?, touchTimestamp: Bool = true) {
        guard isReady, let index = indices[updated.id] else {
            if updated.coverFileName != originalCoverFileName { removeUnreferencedCover(updated.coverFileName) }
            return
        }
        var item = updated
        item.tags = MediaCategory.normalizeTags(item.tags)
        if item.coverFileName == originalCoverFileName {
            item.coverFileName = records[index].coverFileName
        } else {
            coverImports.removeValue(forKey: updated.id)?.cancel()
        }
        if touchTimestamp { item.updatedAt = Date() }
        ensureManagedTagsInclude(item.tags)
        replaceRecord(at: index, with: item)
    }

    func updateStatus(for id: UUID, to status: TrackingStatus) {
        guard isReady, let index = indices[id], records[index].status != status else { return }
        var item = records[index]
        item.status = status
        item.updatedAt = Date()
        replaceRecord(at: index, with: item)
        let quoted = item.quotedTitle(in: language)
        let label = item.category.statusLabel(for: status, in: language)
        showToast(language.tr("\(quoted)已移至「\(label)」", "Moved \(quoted) to \(label)"))
    }

    func updateRating(for id: UUID, rating: Int) {
        let clamped = min(max(rating, 0), 5)
        guard isReady, let index = indices[id], records[index].rating != clamped else { return }
        var item = records[index]
        item.rating = clamped
        item.updatedAt = Date()
        replaceRecord(at: index, with: item)
    }

    func updateTimelineDates(for id: UUID, startedAt: Date?, finishedAt: Date?) {
        guard isReady, let index = indices[id] else { return }
        let normalizedStart: Date?
        let normalizedEnd: Date?
        if let s = startedAt, let f = finishedAt, s > f {
            normalizedStart = f
            normalizedEnd = s
        } else {
            normalizedStart = startedAt
            normalizedEnd = finishedAt
        }
        guard records[index].startedAt != normalizedStart || records[index].finishedAt != normalizedEnd else { return }
        var item = records[index]
        item.startedAt = normalizedStart
        item.finishedAt = normalizedEnd
        item.isSample = false
        replaceRecord(at: index, with: item)
    }

    /// Typing notes leaves the sort order alone. Only an active search depends on the text.
    func updateNotes(for id: UUID, notes: String) {
        guard isReady, let index = indices[id], records[index].notes != notes else { return }
        records[index].notes = notes
        if selectedItemID == id { refreshSelectedItem() }
        notesRevision &+= 1
        scheduleSave(after: .milliseconds(300))
    }

    func importCover(_ source: CoverSource, for id: UUID) {
        guard indices[id] != nil else { return }
        coverImports[id]?.cancel()
        coverImports[id] = Task { [weak self] in
            do {
                let saved = try await CoverManager.shared.saveCover(from: source)
                guard !Task.isCancelled, let self else {
                    CoverManager.shared.removeCover(fileName: saved)
                    return
                }
                coverImports.removeValue(forKey: id)
                updateCover(for: id, newCoverFileName: saved)
            } catch {
                guard !Task.isCancelled, let self else { return }
                coverImports.removeValue(forKey: id)
                showToast(error.localizedDescription)
            }
        }
    }

    func updateCover(for id: UUID, newCoverFileName: String?) {
        coverImports.removeValue(forKey: id)?.cancel()
        guard isReady, let index = indices[id] else {
            removeUnreferencedCover(newCoverFileName)
            return
        }
        guard records[index].coverFileName != newCoverFileName else { return }
        var item = records[index]
        item.coverFileName = newCoverFileName
        replaceRecord(at: index, with: item)
        let quoted = item.quotedTitle(in: language)
        if newCoverFileName != nil {
            showToast(language.tr("已更换\(quoted)的封面", "Updated cover for \(quoted)"))
        } else {
            showToast(language.tr("已恢复\(quoted)的默认封面", "Reset cover for \(quoted)"))
        }
    }

    func deleteItem(id: UUID) {
        guard isReady, let index = indices[id] else { return }
        coverImports.removeValue(forKey: id)?.cancel()
        var updated = records
        let removed = updated.remove(at: index)
        if selectedItemID == id { selectedItemID = nil }
        replaceRecords(with: updated)
        scheduleSave(removing: [removed.coverFileName])
        let quoted = removed.quotedTitle(in: language)
        showToast(language.tr("已删除\(quoted)", "Deleted \(quoted)"))
    }

    func clearSampleItems() {
        guard isReady, hasSampleItems else { return }
        let samples = records.filter(\.isSample)
        for item in samples { coverImports.removeValue(forKey: item.id)?.cancel() }
        if selectedItem?.isSample == true { selectedItemID = nil }
        replaceRecords(with: records.filter { !$0.isSample })
        scheduleSave(removing: samples.map(\.coverFileName))
        showToast(language.tr("已清空示例数据", "Cleared sample data"))
    }

    func restoreSampleItems() {
        guard isReady else { return }
        let samples = Self.makeStarterSamples()
        ensureManagedTagsInclude(samples.flatMap(\.tags))
        replaceRecords(with: records + samples)
        scheduleSave()
        showToast(language.tr("已载入示例数据", "Loaded sample data"))
    }

    func showToast(_ message: String) {
        toastTask?.cancel()
        toastMessage = message
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(2200))
            guard !Task.isCancelled else { return }
            self?.toastMessage = nil
        }
    }

    // MARK: - Persistence

    func flushPendingChanges() throws {
        saveTask?.cancel()
        saveTask = nil
        guard let libraryFile, savedRevision != revision else { return }
        try libraryFile.flush(records, tagCategories: tagCategories, tagNodes: tagNodes,
                              writeTags: !tagsCatalogCorrupted)
        savedRevision = revision
        writing = false
        dirtySince = nil
        removeObsoleteCovers(through: revision)
    }

    private func refreshSelectedItem() {
        let item = selectedItemID.flatMap(item(withID:))
        if selectedItem != item { selectedItem = item }
    }

    private func ensureManagedTagsInclude(_ newTags: [String]) {
        guard !newTags.isEmpty else { return }
        let normalized = TagCatalog.normalize(
            categories: tagCategories,
            nodes: tagNodes,
            mergingItemTags: newTags
        )
        if normalized.nodes != tagNodes {
            tagNodes = normalized.nodes
        }
    }

    private func countRecords(in offsets: some Sequence<Int>, destination: SidebarDestination) -> Int {
        var count = 0
        for offset in offsets where destination.includes(records[offset]) { count += 1 }
        return count
    }

    private func usageIndex() -> (byTag: [String: [Int]], untagged: Int) {
        _ = catalogRevision
        if let tagUsage { return tagUsage }
        var byTag: [String: [Int]] = [:]
        var normalizedKeys: [String: String] = [:]
        var untagged = 0
        for (offset, record) in records.enumerated() {
            if record.tags.isEmpty { untagged += 1 }
            for rawTag in record.tags {
                let key: String
                if let normalized = normalizedKeys[rawTag] {
                    key = normalized
                } else {
                    key = MediaCategory.tagMatchKey(rawTag)
                    normalizedKeys[rawTag] = key
                }
                if !key.isEmpty && byTag[key]?.last != offset { byTag[key, default: []].append(offset) }
            }
        }
        tagUsage = (byTag, untagged)
        return (byTag, untagged)
    }

    private func replaceRecords(with items: [MediaItem], index prepared: RecordIndex? = nil) {
        let index = prepared ?? RecordIndex(items)
        records = items
        indices = index.indices
        coverReferences = index.coverReferences
        tagUsage = nil
        if counts != index.counts { counts = index.counts }
        refreshSelectedItem()
        sortRevision &+= 1
        catalogRevision &+= 1
    }

    private func replaceRecord(at index: Int, with item: MediaItem) {
        let old = records[index]
        records[index] = item
        if old.tags != item.tags { tagUsage = nil }
        if old.category != item.category || old.rating != item.rating || old.isSample != item.isSample {
            var updated = counts
            updated.include(old, delta: -1)
            updated.include(item, delta: 1)
            if counts != updated { counts = updated }
        }
        if old.coverFileName != item.coverFileName {
            if let name = old.coverFileName, let count = coverReferences[name] {
                coverReferences[name] = count > 1 ? count - 1 : nil
            }
            if let name = item.coverFileName { coverReferences[name, default: 0] += 1 }
        }
        if selectedItemID == item.id { refreshSelectedItem() }
        if old.updatedAt != item.updatedAt || old.createdAt != item.createdAt || old.rating != item.rating
            || old.title != item.title || old.titleEN != item.titleEN {
            sortRevision &+= 1
        }
        catalogRevision &+= 1
        scheduleSave(removing: old.coverFileName == item.coverFileName ? [] : [old.coverFileName])
    }

    private func scheduleSave(after delay: Duration = .milliseconds(120), removing covers: [String?] = []) {
        guard libraryFile != nil else { return }
        revision &+= 1
        for case let cover? in covers { coversToRemove[cover] = revision }
        let now = ContinuousClock.now
        let dirtySince = self.dirtySince ?? now
        self.dirtySince = dirtySince
        let debounce = min(delay, max(.zero, dirtySince + .seconds(2) - now))
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled, let self else { return }
            saveTask = nil
            writePendingChanges()
        }
    }

    private func writePendingChanges() {
        guard let libraryFile, !writing, savedRevision != revision else { return }
        writing = true
        dirtySince = nil
        let version = revision
        libraryFile.save(records, tagCategories: tagCategories, tagNodes: tagNodes,
                         writeTags: !tagsCatalogCorrupted) { [weak self] result in
            guard let self, version > savedRevision else { return }
            writing = false
            switch result {
            case .success:
                savedRevision = version
                removeObsoleteCovers(through: version)
            case .failure(let error):
                print("Failed to write library.json: \(error)")
                showToast(language.tr("无法保存作品库：\(error.localizedDescription)",
                                      "Could not save library: \(error.localizedDescription)"))
            }
            if saveTask == nil, version != revision { writePendingChanges() }
        }
    }

    private func removeObsoleteCovers(through version: UInt64) {
        let candidates = coversToRemove.filter { $0.value <= version }.keys
        for cover in candidates {
            removeUnreferencedCover(cover)
            coversToRemove.removeValue(forKey: cover)
        }
    }

    private func removeUnreferencedCover(_ name: String?) {
        guard let name, coverReferences[name] == nil else { return }
        CoverManager.shared.removeCover(fileName: name)
    }
}
