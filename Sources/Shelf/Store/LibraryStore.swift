import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class LibraryStore {
    var language: AppLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: "shelf.language") }
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
    private(set) var tagNodes: [TagNode] = []
    var managedTags: [String] { tagNodes.map(\.name) }
    private(set) var toastMessage: String?
    private(set) var isLoading = false
    private(set) var loadFailed = false

    private struct Counts: Equatable {
        var total = 0
        var categories: [MediaCategory: Int] = [:]
        var fiveStar = 0
        var samples = 0

        mutating func include(_ item: MediaItem, delta: Int) {
            total += delta
            categories[item.category, default: 0] += delta
            if item.rating == 5 { fiveStar += delta }
            if item.isSample { samples += delta }
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
                guard let self else { return }
                let initialItems = snapshot.items ?? Self.makeStarterSamples()
                let baseCategories = snapshot.tagCategories ?? TagCatalog.defaultStarterCategories
                let baseNodes = snapshot.tagNodes ?? TagCatalog.defaultStarterNodes
                let normalized = TagCatalog.normalize(
                    categories: baseCategories,
                    nodes: baseNodes,
                    mergingItemTags: initialItems.flatMap(\.tags)
                )
                tagCategories = normalized.categories
                tagNodes = normalized.nodes
                replaceRecords(with: initialItems)
                isLoading = false
                if snapshot.items == nil || snapshot.tagNodes == nil { scheduleSave() }
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
    var totalUntaggedCount: Int { records.reduce(0) { $0 + ($1.tags.isEmpty ? 1 : 0) } }

    func item(withID id: UUID) -> MediaItem? {
        indices[id].map { records[$0] }
    }

    private func refreshSelectedItem() {
        let item = selectedItemID.flatMap(item(withID:))
        if selectedItem != item { selectedItem = item }
    }

    func toggleLanguage() {
        language = (language == .zh) ? .en : .zh
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

    func count(for destination: SidebarDestination) -> Int {
        switch destination {
        case .all: return counts.total
        case .category(let category): return counts.categories[category, default: 0]
        case .fiveStar: return counts.fiveStar
        }
    }

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
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

    func selectSortField(_ field: LibrarySortField) {
        if sortField == field {
            sortAscending.toggle()
        } else {
            sortField = field
            sortAscending = field.defaultAscending
        }
    }

    // MARK: - Tag Search

    func hasSearchTag(_ rawTag: String) -> Bool {
        searchTokens.contains { MediaCategory.tagsMatch($0.tag, rawTag) }
    }

    func addSearchTag(_ rawTag: String) {
        let resolved = resolveTagName(rawTag)
        guard !resolved.isEmpty, !hasSearchTag(resolved) else { return }
        filterUntaggedOnly = false
        searchTokens.append(SearchTagToken(tag: resolved))
    }

    func toggleSearchTag(_ rawTag: String) {
        if hasSearchTag(rawTag) {
            searchTokens.removeAll { MediaCategory.tagsMatch($0.tag, rawTag) }
        } else {
            addSearchTag(rawTag)
        }
    }

    /// Narrows an active ancestor filter when selecting one of its descendants, or intersects unrelated tags.
    func refineTagFilter(with rawTag: String) {
        let resolved = resolveTagName(rawTag)
        guard !resolved.isEmpty else { return }
        if hasSearchTag(resolved) {
            toggleSearchTag(resolved)
            return
        }
        filterUntaggedOnly = false
        if let ancestorIdx = searchTokens.firstIndex(where: {
            TagCatalog.isDescendant(resolved, of: $0.tag, in: tagNodes)
        }) {
            var next = searchTokens
            next[ancestorIdx] = SearchTagToken(tag: resolved)
            searchTokens = next
        } else {
            searchTokens.append(SearchTagToken(tag: resolved))
        }
    }

    func selectSingleTagFilter(_ rawTag: String, switchToAllIfEmptyInCurrentDestination: Bool = false) {
        let resolved = resolveTagName(rawTag)
        guard !resolved.isEmpty else { return }
        let family = expandedTagFamily(for: resolved)
        if switchToAllIfEmptyInCurrentDestination {
            let hasMatchInDestination = records.contains {
                selectedDestination.includes($0) && $0.hasAnyTag(in: family)
            }
            if !hasMatchInDestination && records.contains(where: { $0.hasAnyTag(in: family) }) {
                selectedDestination = .all
                statusFilter = .allShelves
                searchText = ""
            }
        }
        filterUntaggedOnly = false
        searchTokens = [SearchTagToken(tag: resolved)]
    }

    func selectUntaggedFilter(switchToAllIfEmptyInCurrentDestination: Bool = false) {
        if switchToAllIfEmptyInCurrentDestination {
            let hasUntaggedInDestination = records.contains {
                selectedDestination.includes($0) && $0.tags.isEmpty
            }
            if !hasUntaggedInDestination && records.contains(where: { $0.tags.isEmpty }) {
                selectedDestination = .all
                statusFilter = .allShelves
                searchText = ""
            }
        }
        searchTokens = []
        filterUntaggedOnly = true
    }

    func toggleUntaggedFilter() {
        filterUntaggedOnly.toggle()
    }

    func clearSearch() {
        searchText = ""
        searchTokens = []
        filterUntaggedOnly = false
    }

    func commitTypedHashTags() {
        let parsed = LibraryQuery.ParsedSearch(text: searchText)
        guard !parsed.tagTerms.isEmpty else { return }
        for term in parsed.tagTerms {
            addSearchTag(term)
        }
        searchText = parsed.nonTagText
    }

    func topQuickFindItems(matching rawQuery: String, limit: Int = 6) -> [MediaItem] {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, limit > 0 else { return [] }

        func rank(_ item: MediaItem) -> Int {
            let display = item.displayTitle(in: language)
            if display.hasCaseInsensitivePrefix(trimmed)
                || item.title.hasCaseInsensitivePrefix(trimmed)
                || item.titleEN.hasCaseInsensitivePrefix(trimmed) {
                return 0
            }
            if display.localizedCaseInsensitiveContains(trimmed)
                || item.title.localizedCaseInsensitiveContains(trimmed)
                || item.titleEN.localizedCaseInsensitiveContains(trimmed) {
                return 1
            }
            return 2
        }

        let matched = records.filter { LibraryQuery.matches($0, text: trimmed) }
        return Array(
            matched.sorted { lhs, rhs in
                let rl = rank(lhs), rr = rank(rhs)
                if rl != rr { return rl < rr }
                return lhs.updatedAt > rhs.updatedAt
            }
            .prefix(limit)
        )
    }

    private func resolveTagName(_ rawTag: String) -> String {
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

    private static func deduplicateTokens(_ tokens: [SearchTagToken]) -> [SearchTagToken] {
        var seen: Set<String> = []
        var result: [SearchTagToken] = []
        for token in tokens where !token.tag.isEmpty {
            if seen.insert(token.id).inserted {
                result.append(token)
            }
        }
        return result
    }

    // MARK: - Tag Catalog

    func tagExists(_ rawTag: String) -> Bool {
        let canonical = MediaCategory.canonicalTag(rawTag)
        guard !canonical.isEmpty else { return false }
        return tagNodes.contains { MediaCategory.tagsMatch($0.name, canonical) }
    }

    func expandedTagFamily(for rawTag: String) -> [String] {
        TagCatalog.expandedFamily(for: rawTag, in: tagNodes)
    }

    func tagAncestors(of rawTag: String) -> [String] {
        TagCatalog.ancestors(of: rawTag, in: tagNodes)
    }

    func nestedChildCount(for rawTag: String) -> Int {
        TagCatalog.descendants(of: rawTag, in: tagNodes).count
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

    func availableTags(prioritizing category: MediaCategory? = nil, including extra: [String] = []) -> [String] {
        var all = tagNodes.map(\.name)
        for raw in extra {
            let canonical = MediaCategory.canonicalTag(raw)
            guard !canonical.isEmpty else { continue }
            if !all.contains(where: { MediaCategory.tagsMatch($0, canonical) }) {
                all.append(canonical)
            }
        }
        guard let category else { return all }

        var relevant: [String] = []
        var otherStarter: [String] = []
        for tag in all {
            let isPresetForCategory = category.presetTags.contains { MediaCategory.tagsMatch($0, tag) }
            let isDefaultStarter = MediaCategory.defaultStarterTags.contains { MediaCategory.tagsMatch($0, tag) }
            let usedInCategory = records.contains { $0.category == category && $0.hasTag(tag) }
            if isPresetForCategory || !isDefaultStarter || usedInCategory {
                relevant.append(tag)
            } else {
                otherStarter.append(tag)
            }
        }
        return relevant + otherStarter
    }

    func usageCount(
        forTag rawTag: String,
        in destination: SidebarDestination = .all,
        includeDescendants: Bool = false
    ) -> Int {
        if includeDescendants {
            let family = expandedTagFamily(for: rawTag)
            guard !family.isEmpty else { return 0 }
            return records.reduce(0) { count, item in
                guard destination.includes(item) else { return count }
                return count + (item.hasAnyTag(in: family) ? 1 : 0)
            }
        }
        return records.reduce(0) { count, item in
            guard destination.includes(item) else { return count }
            return count + (item.hasTag(rawTag) ? 1 : 0)
        }
    }

    func resolveCategoryName(_ rawCategory: String) -> String? {
        let canonical = MediaCategory.canonicalTag(rawCategory)
        guard !canonical.isEmpty else { return nil }
        return tagCategories.first { MediaCategory.tagsMatch($0, canonical) }
    }

    func tagCount(inCategory rawCategory: String?) -> Int {
        guard let rawCategory else {
            let validIDs = Set(tagCategories.map { $0.lowercased() })
            return tagNodes.filter { node in
                guard let cat = node.category else { return true }
                return !validIDs.contains(cat.lowercased())
            }.count
        }
        let targetID = MediaCategory.canonicalTag(rawCategory).lowercased()
        return tagNodes.filter { $0.category?.lowercased() == targetID }.count
    }

    @discardableResult
    func addTagCategory(_ rawName: String) -> String? {
        let canonical = MediaCategory.canonicalTag(rawName)
        guard !canonical.isEmpty else { return nil }
        if let existing = resolveCategoryName(canonical) {
            return existing
        }
        guard isReady else { return canonical }
        let normalized = TagCatalog.normalize(
            categories: tagCategories + [canonical],
            nodes: tagNodes
        )
        tagCategories = normalized.categories
        tagNodes = normalized.nodes
        catalogRevision &+= 1
        scheduleSave()
        let shown = MediaCategory.localizedTag(canonical, in: language)
        showToast(language.tr("已添加分类「\(shown)」", "Added category “\(shown)”"))
        return canonical
    }

    @discardableResult
    func renameTagCategory(from oldRaw: String, to newRaw: String) -> String? {
        guard isReady, let oldCategory = resolveCategoryName(oldRaw) else { return nil }
        let trimmedNew = MediaCategory.canonicalTag(newRaw)
        guard !trimmedNew.isEmpty else { return nil }

        let existingTarget = tagCategories.first {
            !MediaCategory.tagsMatch($0, oldCategory) && MediaCategory.tagsMatch($0, trimmedNew)
        }
        let target = existingTarget ?? trimmedNew
        let merging = existingTarget != nil

        var updatedCategories: [String] = []
        for cat in tagCategories {
            if MediaCategory.tagsMatch(cat, oldCategory) {
                if !merging {
                    updatedCategories.append(target)
                }
            } else {
                updatedCategories.append(cat)
            }
        }

        let updatedNodes = tagNodes.map { node in
            var copy = node
            if let cat = copy.category, MediaCategory.tagsMatch(cat, oldCategory) {
                copy.category = target
            }
            return copy
        }

        let normalized = TagCatalog.normalize(categories: updatedCategories, nodes: updatedNodes)
        guard normalized.categories != tagCategories || normalized.nodes != tagNodes else { return target }
        tagCategories = normalized.categories
        tagNodes = normalized.nodes
        catalogRevision &+= 1
        scheduleSave()
        let oldShown = MediaCategory.localizedTag(oldCategory, in: language)
        let newShown = MediaCategory.localizedTag(target, in: language)
        showToast(language.tr("已将分类「\(oldShown)」重命名为「\(newShown)」", "Renamed category “\(oldShown)” to “\(newShown)”"))
        return target
    }

    func deleteTagCategory(_ rawName: String) {
        guard isReady, let target = resolveCategoryName(rawName) else { return }
        let updatedCategories = tagCategories.filter { !MediaCategory.tagsMatch($0, target) }
        let updatedNodes = tagNodes.map { node in
            var copy = node
            if let cat = copy.category, MediaCategory.tagsMatch(cat, target) {
                copy.category = nil
            }
            return copy
        }
        let normalized = TagCatalog.normalize(categories: updatedCategories, nodes: updatedNodes)
        tagCategories = normalized.categories
        tagNodes = normalized.nodes
        catalogRevision &+= 1
        scheduleSave()
        let shown = MediaCategory.localizedTag(target, in: language)
        showToast(language.tr("已删除分类「\(shown)」", "Deleted category “\(shown)”"))
    }

    func setTagCategory(_ rawTag: String, category rawCategory: String?) {
        guard isReady else { return }
        guard let idx = tagNodes.firstIndex(where: { MediaCategory.tagsMatch($0.name, rawTag) }) else { return }
        let resolvedCat = rawCategory.flatMap { resolveCategoryName($0) }
        if rawCategory != nil && resolvedCat == nil { return }
        var updated = tagNodes
        updated[idx].category = resolvedCat
        if updated[idx].parent != nil {
            updated[idx].parent = nil
        }
        let normalized = TagCatalog.normalize(categories: tagCategories, nodes: updated)
        guard normalized.nodes != tagNodes else { return }
        tagNodes = normalized.nodes
        catalogRevision &+= 1
        scheduleSave()
    }

    @discardableResult
    func addTag(_ rawTag: String, category rawCategory: String? = nil, parent: String? = nil) -> String? {
        let canonical = MediaCategory.canonicalTag(rawTag)
        guard !canonical.isEmpty else { return nil }
        if let existing = tagNodes.first(where: { MediaCategory.tagsMatch($0.name, canonical) }) {
            return existing.name
        }
        guard isReady else { return canonical }
        let validParent: String?
        let resolvedCategory: String?
        if let parent {
            let resolvedParent = resolveTagName(parent)
            let parentNode = tagNodes.first(where: { MediaCategory.tagsMatch($0.name, resolvedParent) })
            validParent = parentNode?.name
            resolvedCategory = parentNode?.category
        } else {
            validParent = nil
            resolvedCategory = rawCategory.flatMap { resolveCategoryName($0) }
        }
        let normalized = TagCatalog.normalize(
            categories: tagCategories,
            nodes: tagNodes + [TagNode(name: canonical, category: resolvedCategory, parent: validParent)]
        )
        tagCategories = normalized.categories
        tagNodes = normalized.nodes
        catalogRevision &+= 1
        scheduleSave()
        let shown = MediaCategory.localizedTag(canonical, in: language)
        showToast(language.tr("已添加标签「\(shown)」", "Added tag “\(shown)”"))
        return canonical
    }

    @discardableResult
    func renameTag(from oldRaw: String, to newRaw: String) -> String? {
        guard isReady else { return nil }
        let trimmedNew = newRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedNew.isEmpty else { return nil }
        let oldCanonical = MediaCategory.canonicalTag(oldRaw)
        guard !oldCanonical.isEmpty else { return nil }

        let existingTarget = tagNodes.first {
            !MediaCategory.tagsMatch($0.name, oldRaw) && MediaCategory.tagsMatch($0.name, trimmedNew)
        }
        let target = existingTarget?.name ?? trimmedNew
        let mergingIntoExisting = existingTarget != nil

        var newNodes: [TagNode] = []
        var changed = false
        for var node in tagNodes {
            if MediaCategory.tagsMatch(node.name, oldRaw) {
                changed = true
                if mergingIntoExisting {
                    continue
                }
                node.name = target
                if let p = node.parent, MediaCategory.tagsMatch(p, target) {
                    node.parent = nil
                }
            } else if let p = node.parent, MediaCategory.tagsMatch(p, oldRaw) {
                node.parent = target
                changed = true
            }
            newNodes.append(node)
        }
        if existingTarget == nil && !newNodes.contains(where: { MediaCategory.tagsMatch($0.name, target) }) {
            newNodes.append(TagNode(name: target, parent: nil))
            changed = true
        }
        let normalized = TagCatalog.normalize(categories: tagCategories, nodes: newNodes)
        if normalized.nodes != tagNodes {
            changed = true
        }

        var recordsChanged = false
        for index in records.indices where records[index].hasTag(oldRaw) {
            var newTags: [String] = []
            var seenTags: Set<String> = []
            for tag in records[index].tags {
                let replacement = MediaCategory.tagsMatch(tag, oldRaw) ? target : tag
                let key = MediaCategory.canonicalTag(replacement).lowercased()
                if seenTags.insert(key).inserted {
                    newTags.append(replacement)
                }
            }
            if records[index].tags != newTags {
                records[index].tags = newTags
                recordsChanged = true
            }
        }

        let updatedTokens = Self.deduplicateTokens(
            searchTokens.map { token in
                MediaCategory.tagsMatch(token.tag, oldRaw) ? SearchTagToken(tag: target) : token
            }
        )
        if updatedTokens.map(\.tag) != searchTokens.map(\.tag) {
            searchTokens = updatedTokens
            changed = true
        }

        guard changed || recordsChanged else { return target }
        tagNodes = normalized.nodes
        refreshSelectedItem()
        catalogRevision &+= 1
        scheduleSave()
        let oldShown = MediaCategory.localizedTag(oldRaw, in: language)
        let newShown = MediaCategory.localizedTag(target, in: language)
        showToast(language.tr("已将「\(oldShown)」重命名为「\(newShown)」", "Renamed “\(oldShown)” to “\(newShown)”"))
        return target
    }

    func setTagParent(_ rawTag: String, parent newParent: String?) {
        guard isReady, TagCatalog.canSetParent(of: rawTag, to: newParent, in: tagNodes) else { return }
        let targetParent = newParent.map { resolveTagName($0) }
        var updated = tagNodes
        guard let idx = updated.firstIndex(where: { MediaCategory.tagsMatch($0.name, rawTag) }) else { return }
        guard updated[idx].parent != targetParent else { return }
        updated[idx].parent = targetParent
        if let targetParent,
           let parentNode = updated.first(where: { MediaCategory.tagsMatch($0.name, targetParent) }) {
            updated[idx].category = parentNode.category
        }
        tagNodes = TagCatalog.normalize(categories: tagCategories, nodes: updated).nodes
        catalogRevision &+= 1
        scheduleSave()
    }

    func moveTag(_ rawTag: String, toParent newParent: String?, before beforeSibling: String?) {
        guard isReady, TagCatalog.canSetParent(of: rawTag, to: newParent, in: tagNodes) else { return }
        guard let sourceIdx = tagNodes.firstIndex(where: { MediaCategory.tagsMatch($0.name, rawTag) }) else { return }
        var node = tagNodes[sourceIdx]
        let targetParent = newParent.map { resolveTagName($0) }
        node.parent = targetParent
        if let targetParent,
           let parentNode = tagNodes.first(where: { MediaCategory.tagsMatch($0.name, targetParent) }) {
            node.category = parentNode.category
        }

        var remaining = tagNodes
        remaining.remove(at: sourceIdx)

        if let beforeSibling,
           !MediaCategory.tagsMatch(beforeSibling, rawTag),
           let destIdx = remaining.firstIndex(where: { MediaCategory.tagsMatch($0.name, beforeSibling) }) {
            remaining.insert(node, at: destIdx)
        } else {
            remaining.append(node)
        }

        let normalized = TagCatalog.normalize(categories: tagCategories, nodes: remaining).nodes
        guard normalized != tagNodes else { return }
        tagNodes = normalized
        catalogRevision &+= 1
        scheduleSave()
    }

    func deleteTag(_ rawTag: String) {
        guard isReady else { return }
        let family = expandedTagFamily(for: rawTag)
        guard !family.isEmpty else { return }

        let filteredNodes = tagNodes.filter { node in
            !family.contains { MediaCategory.tagsMatch($0, node.name) }
        }
        var changed = filteredNodes.count != tagNodes.count

        for index in records.indices where records[index].hasAnyTag(in: family) {
            let filtered = records[index].tags.filter { tag in
                !family.contains { MediaCategory.tagsMatch($0, tag) }
            }
            if filtered != records[index].tags {
                records[index].tags = filtered
                changed = true
            }
        }

        let remainingTokens = searchTokens.filter { token in
            !family.contains { MediaCategory.tagsMatch($0, token.tag) }
        }
        if remainingTokens.count != searchTokens.count {
            searchTokens = remainingTokens
            changed = true
        }

        guard changed else { return }
        tagNodes = TagCatalog.normalize(categories: tagCategories, nodes: filteredNodes).nodes
        refreshSelectedItem()
        catalogRevision &+= 1
        scheduleSave()
        let shown = MediaCategory.localizedTag(rawTag, in: language)
        showToast(language.tr("已删除标签「\(shown)」", "Deleted tag “\(shown)”"))
    }

    func toggleItemTag(_ rawTag: String, for id: UUID) {
        guard isReady, let item = item(withID: id) else { return }
        if item.hasTag(rawTag) {
            let next = item.tags.filter { !MediaCategory.tagsMatch($0, rawTag) }
            updateTags(for: id, tags: next)
        } else {
            let resolved = resolveTagName(rawTag)
            guard !resolved.isEmpty else { return }
            updateTags(for: id, tags: item.tags + [resolved])
        }
    }

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

    // MARK: - CRUD

    private func replaceRecords(with items: [MediaItem]) {
        records = items
        indices.removeAll(keepingCapacity: true)
        indices.reserveCapacity(items.count)
        coverReferences.removeAll(keepingCapacity: true)
        var updated = Counts()
        for (index, item) in items.enumerated() {
            if indices[item.id] == nil { indices[item.id] = index }
            if let name = item.coverFileName { coverReferences[name, default: 0] += 1 }
            updated.include(item, delta: 1)
        }
        if counts != updated { counts = updated }
        refreshSelectedItem()
        sortRevision &+= 1
        catalogRevision &+= 1
    }

    private func replaceRecord(at index: Int, with item: MediaItem) {
        let old = records[index]
        records[index] = item
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

    @discardableResult
    func addItem(_ item: MediaItem) -> MediaItem {
        guard isReady else { return item }
        var newItem = item
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

    // MARK: - Persistence & Backup

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
        libraryFile.save(records, tagCategories: tagCategories, tagNodes: tagNodes) { [weak self] result in
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

    func flushPendingChanges() throws {
        saveTask?.cancel()
        saveTask = nil
        guard let libraryFile, savedRevision != revision else { return }
        try libraryFile.flush(records, tagCategories: tagCategories, tagNodes: tagNodes)
        savedRevision = revision
        writing = false
        dirtySince = nil
        removeObsoleteCovers(through: revision)
    }

    func exportLibraryJSON() {
        guard isReady else { return }
        let panel = NSSavePanel()
        panel.title = language.tr("导出备份文件", "Export Backup File")
        panel.nameFieldStringValue = language.tr("作品库备份.json", "Shelf-Backup.json")
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let items = records

        Task {
            do {
                try await Task.detached(priority: .utility) {
                    try LibraryFile.write(items, to: url, formatted: true)
                }.value
                showToast(language.tr("数据已导出", "Backup exported"))
            } catch {
                showToast(language.tr("导出失败：\(error.localizedDescription)", "Export failed: \(error.localizedDescription)"))
            }
        }
    }

    func importLibraryJSON() {
        guard isReady else { return }
        let panel = NSOpenPanel()
        panel.title = language.tr("导入备份文件", "Import Backup File")
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            do {
                let imported = try await Task.detached(priority: .utility) {
                    try LibraryFile.read(from: url)
                }.value
                var ids = Set(indices.keys)
                let newItems = imported.filter { ids.insert($0.id).inserted }
                if !newItems.isEmpty {
                    ensureManagedTagsInclude(newItems.flatMap(\.tags))
                    replaceRecords(with: records + newItems)
                    scheduleSave()
                }
                showToast(language.tr("已成功导入 \(newItems.count) 条记录", "Imported \(newItems.count) items"))
            } catch {
                showToast(language.tr("导入失败：文件格式不兼容", "Import failed: incompatible file format"))
            }
        }
    }

    // MARK: - Starter Sample Library

    static func makeStarterSamples() -> [MediaItem] {
        let now = Date()
        func ago(_ hours: Double) -> Date {
            now.addingTimeInterval(-hours * 3600)
        }

        return [
            MediaItem(
                title: "博德之门 3",
                titleEN: "Baldur's Gate 3",
                category: .game,
                status: .active,
                subtag: "Steam",
                rating: 5,
                notes: "自由度惊人的 CRPG，第三章下城区的支线密度太夸张了。每次掷骰子都有跑团的惊喜感。",
                paletteSeed: 108,
                createdAt: ago(120),
                updatedAt: ago(2),
                isSample: true
            ),
            MediaItem(
                title: "葬送的芙莉莲",
                titleEN: "Frieren: Beyond Journey's End",
                category: .video,
                status: .active,
                subtag: "番剧",
                rating: 5,
                notes: "勇者打倒魔王之后的旅途，节奏淡雅却后劲极强，配乐与分镜都是顶级水准。",
                paletteSeed: 214,
                createdAt: ago(96),
                updatedAt: ago(5),
                isSample: true
            ),
            MediaItem(
                title: "三体",
                titleEN: "The Three-Body Problem",
                category: .novel,
                status: .completed,
                subtag: "科幻",
                rating: 5,
                notes: "从红岸基地到黑暗森林再到二向箔，恢弘的宇宙尺度让人久久震撼。",
                paletteSeed: 309,
                createdAt: ago(300),
                updatedAt: ago(40),
                isSample: true
            ),
            MediaItem(
                title: "塞尔达传说：旷野之息",
                titleEN: "The Legend of Zelda: Breath of the Wild",
                category: .game,
                status: .completed,
                subtag: "Switch",
                rating: 5,
                notes: "走出复苏神庙俯瞰海拉鲁大陆的那一刻，真正定义了开放世界的浪漫。",
                paletteSeed: 412,
                createdAt: ago(500),
                updatedAt: ago(72),
                isSample: true
            ),
            MediaItem(
                title: "星际穿越",
                titleEN: "Interstellar",
                category: .video,
                status: .completed,
                subtag: "电影",
                rating: 5,
                notes: "米勒星球掀起巨浪与管风琴响起的一幕，值得每年重温一遍。",
                paletteSeed: 520,
                createdAt: ago(420),
                updatedAt: ago(90),
                isSample: true
            ),
            MediaItem(
                title: "极乐迪斯科",
                titleEN: "Disco Elysium",
                category: .game,
                status: .backlog,
                subtag: "Steam",
                rating: 0,
                notes: "听说文本量与美术风格像一本可以游玩的现代主义小说，留着长假静下心玩。",
                paletteSeed: 635,
                createdAt: ago(60),
                updatedAt: ago(24),
                isSample: true
            ),
            MediaItem(
                title: "百年孤独",
                titleEN: "One Hundred Years of Solitude",
                category: .novel,
                status: .backlog,
                subtag: "文学",
                rating: 0,
                notes: "准备配着布恩迪亚家族人物关系图一起读完。",
                paletteSeed: 742,
                createdAt: ago(48),
                updatedAt: ago(30),
                isSample: true
            ),
            MediaItem(
                title: "人生切割术",
                titleEN: "Severance",
                category: .video,
                status: .backlog,
                subtag: "电视剧",
                rating: 0,
                notes: "构思极妙的悬疑科幻剧，周末准备开追。",
                paletteSeed: 856,
                createdAt: ago(36),
                updatedAt: ago(18),
                isSample: true
            )
        ]
    }
}
