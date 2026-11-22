import Foundation

/// The fields needed by the poster wall. Detail-only edits don't change a card.
struct LibraryPoster: Equatable, Sendable {
    let id: UUID
    let title: String
    let secondaryTitle: String?
    let category: MediaCategory
    let status: TrackingStatus
    let subtag: String
    let rating: Int
    let coverFileName: String?
    let paletteSeed: Int
    let startedAt: Date?
    let finishedAt: Date?

    init(_ item: MediaItem, language: AppLanguage) {
        id = item.id
        title = item.displayTitle(in: language)
        secondaryTitle = item.secondaryTitle(in: language)
        category = item.category
        status = item.status
        subtag = item.subtag
        rating = item.rating
        coverFileName = item.coverFileName
        paletteSeed = item.paletteSeed
        startedAt = item.startedAt
        finishedAt = item.finishedAt
    }

    func effectiveTimelineSpan(now: Date = Date()) -> (start: Date, end: Date, isOngoing: Bool)? {
        switch (startedAt, finishedAt) {
        case (.some(let s), .some(let f)):
            return (min(s, f), max(s, f), false)
        case (.some(let s), nil):
            if status == .active {
                return (s, max(s, now), true)
            }
            return (s, s, false)
        case (nil, .some(let f)):
            return (f, f, false)
        case (nil, nil):
            return nil
        }
    }
}

struct ShelfSectionModel: Equatable, Sendable {
    let status: TrackingStatus?
    let title: String
    let totalCount: Int
    var isCollapsed = false
    let items: [LibraryPoster]

    var visibleCount: Int { isCollapsed ? 0 : items.count }
}

struct TagGroupFilter: Equatable, Hashable, Sendable {
    let rootTag: String
    let matchingTags: [String]
}

struct LibraryProjection: Sendable {
    static let empty = LibraryProjection(
        sections: [],
        count: 0,
        statusCounts: [:],
        subtags: [],
        tagCounts: [:],
        narrowedTagCounts: [:],
        untaggedCount: 0,
        showStatusBadges: false
    )

    let sections: [ShelfSectionModel]
    let count: Int
    let statusCounts: [TrackingStatus: Int]
    let subtags: [String]
    let tagCounts: [String: Int]
    let narrowedTagCounts: [String: Int]
    let untaggedCount: Int
    let showStatusBadges: Bool
}

/// Keeps collation and search independent of tab/tag changes. All indices refer to the
/// same catalog revision, so display order and the counts always use the same records.
struct LibraryQuery {
    struct ParsedSearch: Equatable {
        let tagTerms: [String]
        let freeText: String
        let nonTagText: String

        var isEmpty: Bool {
            tagTerms.isEmpty && freeText.isEmpty
        }

        init(text: String) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                self.tagTerms = []
                self.freeText = ""
                self.nonTagText = ""
                return
            }

            let parts = trimmed.split(whereSeparator: \.isWhitespace)
            var parsedTags: [String] = []
            var nonTagParts: [Substring] = []
            var sawTagPrefix = false

            for part in parts {
                if let body = Self.extractPrefixedTag(from: part) {
                    sawTagPrefix = true
                    if !body.isEmpty {
                        parsedTags.append(body)
                    }
                } else {
                    nonTagParts.append(part)
                }
            }

            self.tagTerms = parsedTags
            let remaining = nonTagParts.joined(separator: " ")
            self.nonTagText = remaining
            self.freeText = sawTagPrefix ? remaining : trimmed
        }

        static func extractPrefixedTag(from token: Substring) -> String? {
            for prefix in ["#", "＃", "标签:", "标签："] {
                if token.hasPrefix(prefix) {
                    return String(token.dropFirst(prefix.count))
                }
            }
            if token.count >= 4 {
                let prefixEnd = token.index(token.startIndex, offsetBy: 4)
                let head = token[..<prefixEnd]
                if head.caseInsensitiveCompare("tag:") == .orderedSame
                    || head.caseInsensitiveCompare("tag：") == .orderedSame {
                    return String(token[prefixEnd...])
                }
            }
            return nil
        }
    }

    struct Options: Equatable, Sendable {
        let destination: SidebarDestination
        let status: StatusFilterOption
        let tagGroups: [TagGroupFilter]
        let untaggedOnly: Bool
        let text: String
        let sortField: LibrarySortField
        let ascending: Bool
        let language: AppLanguage
    }

    struct Request: Equatable, Sendable {
        let revision: UInt64
        let sortRevision: UInt64
        let notesRevision: UInt64
        let options: Options
    }

    struct QuickFindRequest: Equatable, Sendable {
        let text: String
        let language: AppLanguage
        let revision: UInt64
        let notesRevision: UInt64
        var limit: Int = 6
    }

    actor Worker {
        private var query = LibraryQuery()

        func project(_ records: [MediaItem], request: Request) -> LibraryProjection? {
            guard !Task.isCancelled else { return nil }
            return query.project(records, request: request)
        }

        func quickFind(_ records: [MediaItem], request: QuickFindRequest) -> [MediaItem]? {
            guard !Task.isCancelled else { return nil }
            return LibraryQuery.quickFind(records, text: request.text, language: request.language, limit: request.limit)
        }
    }

    private struct SortKey: Equatable {
        let revision: UInt64
        let field: LibrarySortField
        let ascending: Bool
        let language: AppLanguage?
    }

    private struct SearchKey: Equatable {
        let revision: UInt64
        let notesRevision: UInt64
        let text: String
    }

    private struct ProjectionKey: Equatable {
        let search: SearchKey
        let sortRevision: UInt64
        let options: Options
    }

    private var sortOrders: [(key: SortKey, indices: [Int])] = []
    private var searchResults: [(key: SearchKey, matches: [Bool])] = []
    private var projected: (ProjectionKey, LibraryProjection)?

    mutating func project(_ records: [MediaItem], request: Request) -> LibraryProjection {
        let options = request.options
        let parsed = ParsedSearch(text: options.text)
        let searchKey = SearchKey(
            revision: request.revision,
            notesRevision: parsed.freeText.isEmpty ? 0 : request.notesRevision,
            text: options.text
        )
        let projectionKey = ProjectionKey(search: searchKey, sortRevision: request.sortRevision, options: options)
        if let (key, result) = projected, key == projectionKey {
            return result
        }

        let sortKey = SortKey(revision: request.sortRevision, field: options.sortField, ascending: options.ascending,
                              language: options.sortField == .title ? options.language : nil)
        if sortOrders.first?.key.revision != sortKey.revision {
            sortOrders.removeAll(keepingCapacity: true)
        }
        let indexes: [Int]
        if let hit = sortOrders.firstIndex(where: { $0.key == sortKey }) {
            indexes = sortOrders.remove(at: hit).indices
        } else {
            indexes = Self.sortedIndices(records, key: sortKey)
        }
        sortOrders.append((sortKey, indexes))
        if sortOrders.count > 4 { sortOrders.removeFirst() }
        let isSearching = !parsed.isEmpty
        if searchResults.first?.key.revision != searchKey.revision {
            searchResults.removeAll(keepingCapacity: true)
        }
        let searchMatches: [Bool]?
        if !isSearching {
            searchMatches = nil
        } else {
            let matches: [Bool]
            if let hit = searchResults.firstIndex(where: { $0.key == searchKey }) {
                matches = searchResults.remove(at: hit).matches
            } else {
                matches = Self.search(records, parsed: parsed)
            }
            searchMatches = matches
            searchResults.append((searchKey, matches))
            if searchResults.count > 6 { searchResults.removeFirst() }
        }

        let usesShelves = options.status == .allShelves && !isSearching
        var statusCounts: [TrackingStatus: Int] = [:]
        var tagCounts: [String: Int] = [:]
        var narrowedTagCounts: [String: Int] = [:]
        var untaggedCount = 0
        var shelves: [TrackingStatus: [LibraryPoster]] = [:]
        var flat: [LibraryPoster] = []
        var count = 0

        let category = options.destination.activeCategory
        let tagGroups = options.tagGroups.map { Set($0.matchingTags.map(MediaCategory.tagMatchKey)) }
        let hasTagFilter = options.untaggedOnly || !tagGroups.isEmpty
        var tagMetadata: [String: (name: String, key: String)] = [:]
        for index in indexes {
            if let searchMatches, !searchMatches[index] { continue }
            let item = records[index]
            guard options.destination.includes(item) else { continue }
            let statusMatches = options.status == .allShelves || options.status == .single(item.status)
            let matchesTags: Bool
            if tagGroups.isEmpty || options.untaggedOnly {
                matchesTags = !options.untaggedOnly || item.tags.isEmpty
            } else {
                matchesTags = tagGroups.allSatisfy { group in
                    item.tags.contains { rawTag in
                        let key = Self.tagInfo(rawTag, cache: &tagMetadata).key
                        return !key.isEmpty && group.contains(key)
                    }
                }
            }
            if matchesTags {
                statusCounts[item.status, default: 0] += 1
            }
            guard statusMatches else { continue }
            if item.tags.isEmpty {
                untaggedCount += 1
            } else {
                for rawTag in item.tags {
                    let tag = Self.tagInfo(rawTag, cache: &tagMetadata).name
                    if !tag.isEmpty {
                        tagCounts[tag, default: 0] += 1
                        if hasTagFilter && matchesTags {
                            narrowedTagCounts[tag, default: 0] += 1
                        }
                    }
                }
            }
            guard matchesTags else { continue }

            let poster = LibraryPoster(item, language: options.language)
            count += 1
            if usesShelves {
                shelves[item.status, default: []].append(poster)
            } else {
                flat.append(poster)
            }
        }

        let sections: [ShelfSectionModel]
        if usesShelves {
            sections = TrackingStatus.shelfOrder.compactMap { status in
                guard let posters = shelves[status] else { return nil }
                return ShelfSectionModel(status: status,
                                         title: status.localizedTitle(in: category, lang: options.language),
                                         totalCount: posters.count, items: posters)
            }
        } else {
            sections = [ShelfSectionModel(status: nil, title: "", totalCount: flat.count, items: flat)]
        }

        let tags = tagCounts.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending
        }.map(\.key)
        let result = LibraryProjection(sections: sections, count: count, statusCounts: statusCounts,
                                       subtags: tags, tagCounts: tagCounts,
                                       narrowedTagCounts: hasTagFilter ? narrowedTagCounts : tagCounts,
                                       untaggedCount: untaggedCount,
                                       showStatusBadges: options.status == .allShelves && isSearching)
        projected = (projectionKey, result)
        return result
    }

    private static func tagInfo(_ rawTag: String, cache: inout [String: (name: String, key: String)])
        -> (name: String, key: String) {
        if let info = cache[rawTag] { return info }
        let name = MediaCategory.canonicalTag(rawTag)
        let info = (name, name.folding(options: .caseInsensitive, locale: nil))
        cache[rawTag] = info
        return info
    }

    static func matches(
        _ item: MediaItem,
        text: String,
        tagGroups: [TagGroupFilter] = [],
        untaggedOnly: Bool = false
    ) -> Bool {
        if untaggedOnly {
            if !item.tags.isEmpty { return false }
        } else if !tagGroups.isEmpty {
            if !tagGroups.allSatisfy({ item.hasAnyTag(in: $0.matchingTags) }) {
                return false
            }
        }
        let parsed = ParsedSearch(text: text)
        guard !parsed.isEmpty else { return true }
        var matcher = SearchMatcher(parsed: parsed)
        return matcher.matches(item)
    }

    private static func search(_ records: [MediaItem], parsed: ParsedSearch) -> [Bool] {
        var matcher = SearchMatcher(parsed: parsed)
        return records.map { matcher.matches($0) }
    }

    static func quickFind(_ records: [MediaItem], text: String, language: AppLanguage, limit: Int) -> [MediaItem] {
        let parsed = ParsedSearch(text: text)
        guard !parsed.isEmpty, limit > 0 else { return [] }
        let rankQuery = parsed.freeText.isEmpty ? text.trimmed : parsed.freeText
        typealias Candidate = (rank: Int, item: MediaItem)
        func ranksBefore(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            return lhs.item.updatedAt > rhs.item.updatedAt
        }

        var matcher = SearchMatcher(parsed: parsed)
        var results: [Candidate] = []
        // Keep the normal six-result search bounded. Larger callers get a stable sort.
        let keepTop = limit <= 32
        for item in records {
            if keepTop, results.count == limit, let last = results.last,
               last.rank == 0, item.updatedAt <= last.item.updatedAt { continue }
            guard matcher.matches(item) else { continue }
            let displayTitle = item.displayTitle(in: language)
            let displayIsDistinct = displayTitle != item.title && displayTitle != item.titleEN
            let rank: Int
            if !parsed.freeText.isEmpty {
                if item.title.hasCaseInsensitivePrefix(rankQuery) || item.titleEN.hasCaseInsensitivePrefix(rankQuery)
                    || (displayIsDistinct && displayTitle.hasCaseInsensitivePrefix(rankQuery)) {
                    rank = 0
                } else if item.title.localizedCaseInsensitiveContains(rankQuery) || item.titleEN.localizedCaseInsensitiveContains(rankQuery)
                    || (displayIsDistinct && displayTitle.localizedCaseInsensitiveContains(rankQuery)) {
                    rank = 1
                } else {
                    rank = 2
                }
            } else {
                rank = 2
            }
            let candidate = (rank, item)
            if keepTop {
                let position = results.firstIndex { ranksBefore(candidate, $0) } ?? results.endIndex
                if position < limit {
                    results.insert(candidate, at: position)
                    if results.count > limit { results.removeLast() }
                }
            } else {
                results.append(candidate)
            }
        }
        if !keepTop { results.sort(by: ranksBefore) }
        return results.prefix(limit).map(\.item)
    }

    /// Computes tag-narrowing suggestions for the active filter bar, prioritizing direct children of active tags.
    static func narrowingTags(
        for projection: LibraryProjection,
        catalogNodes: [TagNode],
        activeTokens: [SearchTagToken],
        untaggedOnly: Bool,
        limit: Int = 8
    ) -> [String] {
        guard !untaggedOnly else { return [] }
        let counts = activeTokens.isEmpty ? projection.tagCounts : projection.narrowedTagCounts
        guard !counts.isEmpty else { return [] }
        let activeKeys = Set(activeTokens.map(\.id))
        let tree = TagCatalog.Tree(catalogNodes)
        let outline = tree.flattenedOutline(collapsedIDs: [])
        let activeAncestors = Set(
            outline.lazy
                .filter { activeKeys.contains($0.node.id) }
                .flatMap(\.ancestors)
                .map(MediaCategory.tagMatchKey)
        )

        var candidates: [(isChildOfActive: Bool, count: Int, order: Int, name: String)] = []
        for (idx, row) in outline.enumerated() {
            let name = row.node.name
            if activeKeys.contains(row.node.id) || activeAncestors.contains(row.node.id) { continue }
            let family = tree.expandedFamily(for: name)
            let matchedCount = family.reduce(0) { $0 + counts[$1, default: 0] }
            guard matchedCount > 0 else { continue }
            let isChildOfActive = row.node.parent.map { activeKeys.contains(MediaCategory.tagMatchKey($0)) } ?? false
            candidates.append((isChildOfActive, matchedCount, idx, name))
        }

        return candidates
            .sorted { lhs, rhs in
                if lhs.isChildOfActive != rhs.isChildOfActive { return lhs.isChildOfActive }
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.order < rhs.order
            }
            .prefix(limit)
            .map(\.name)
    }

    private struct SearchMatcher {
        let parsed: ParsedSearch
        let matchingCategories: Set<MediaCategory>
        var tagTermMatches: [[String: Bool]]
        var freeTextTagMatches: [String: Bool] = [:]

        init(parsed: ParsedSearch) {
            self.parsed = parsed
            tagTermMatches = Array(repeating: [:], count: parsed.tagTerms.count)
            if parsed.freeText.isEmpty {
                matchingCategories = []
            } else {
                let text = parsed.freeText
                matchingCategories = Set(MediaCategory.allCases.filter {
                    $0.title(in: .zh).localizedCaseInsensitiveContains(text)
                        || $0.title(in: .en).localizedCaseInsensitiveContains(text)
                })
            }
        }

        mutating func matches(_ item: MediaItem) -> Bool {
            for (index, term) in parsed.tagTerms.enumerated() {
                let hasMatchingTag = item.tags.contains { tag in
                    guard !tag.isEmpty else { return false }
                    if let cached = tagTermMatches[index][tag] { return cached }
                    let matches = Self.tag(tag, matchesTerm: term)
                    tagTermMatches[index][tag] = matches
                    return matches
                }
                if !hasMatchingTag {
                    return false
                }
            }

            let text = parsed.freeText
            guard !text.isEmpty else { return true }

            if matchingCategories.contains(item.category)
                || item.title.localizedCaseInsensitiveContains(text)
                || item.titleEN.localizedCaseInsensitiveContains(text) {
                return true
            }
            for tag in item.tags where !tag.isEmpty {
                if let cached = freeTextTagMatches[tag] {
                    if cached { return true }
                    continue
                }
                let match = Self.tag(tag, matchesTerm: text)
                freeTextTagMatches[tag] = match
                if match { return true }
            }
            return item.notes.localizedCaseInsensitiveContains(text)
        }

        private static func tag(_ tag: String, matchesTerm term: String) -> Bool {
            tag.localizedCaseInsensitiveContains(term)
                || MediaCategory.localizedTag(tag, in: .en).localizedCaseInsensitiveContains(term)
                || MediaCategory.localizedTag(tag, in: .zh).localizedCaseInsensitiveContains(term)
        }
    }

    private static let pinyinLocale = Locale(identifier: "zh-Hans-CN")
    private static let englishLocale = Locale(identifier: "en_US")

    private static func sortedIndices(_ records: [MediaItem], key: SortKey) -> [Int] {
        switch key.field {
        case .updatedAt:
            return records.indices.sorted {
                let lhs = records[$0], rhs = records[$1]
                if lhs.updatedAt != rhs.updatedAt {
                    return key.ascending ? lhs.updatedAt < rhs.updatedAt : lhs.updatedAt > rhs.updatedAt
                }
                return lhs.createdAt > rhs.createdAt
            }
        case .createdAt:
            return records.indices.sorted {
                let lhs = records[$0], rhs = records[$1]
                if lhs.createdAt != rhs.createdAt {
                    return key.ascending ? lhs.createdAt < rhs.createdAt : lhs.createdAt > rhs.createdAt
                }
                return lhs.updatedAt > rhs.updatedAt
            }
        case .rating:
            return records.indices.sorted {
                let lhs = records[$0], rhs = records[$1]
                let lhsRated = lhs.rating > 0, rhsRated = rhs.rating > 0
                if lhsRated != rhsRated { return lhsRated }
                if lhs.rating != rhs.rating {
                    return key.ascending ? lhs.rating < rhs.rating : lhs.rating > rhs.rating
                }
                return lhs.updatedAt > rhs.updatedAt
            }
        case .title:
            let language = key.language ?? .zh
            let locale = language == .zh ? pinyinLocale : englishLocale
            let titles = records.map { $0.displayTitle(in: language) }
            return records.indices.sorted {
                let comparison = titles[$0].compare(titles[$1], options: [.caseInsensitive, .numeric, .widthInsensitive],
                                                     range: nil, locale: locale)
                if comparison != .orderedSame {
                    return comparison == (key.ascending ? .orderedAscending : .orderedDescending)
                }
                return records[$0].updatedAt > records[$1].updatedAt
            }
        }
    }
}

extension SidebarDestination {
    func includes(_ item: MediaItem) -> Bool {
        switch self {
        case .all, .timeline: return true
        case .category(let category): return item.category == category
        case .fiveStar: return item.rating == 5
        }
    }
}
