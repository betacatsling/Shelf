import Foundation

/// The fields needed by the poster wall. Detail-only edits don't change a card.
struct LibraryPoster: Equatable, Sendable {
    let id: UUID
    let title: String
    let category: MediaCategory
    let status: TrackingStatus
    let subtag: String
    let rating: Int
    let coverFileName: String?
    let paletteSeed: Int

    init(_ item: MediaItem, language: AppLanguage) {
        id = item.id
        title = item.displayTitle(in: language)
        category = item.category
        status = item.status
        subtag = item.subtag
        rating = item.rating
        coverFileName = item.coverFileName
        paletteSeed = item.paletteSeed
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

struct LibraryProjection: Sendable {
    static let empty = LibraryProjection(sections: [], count: 0, statusCounts: [:], subtags: [], showStatusBadges: false)

    let sections: [ShelfSectionModel]
    let count: Int
    let statusCounts: [TrackingStatus: Int]
    let subtags: [String]
    let showStatusBadges: Bool
}

/// Keeps collation and search independent of tab/tag changes. All indices refer to the
/// same catalog revision, so display order and the counts always use the same records.
struct LibraryQuery {
    struct Options: Equatable, Sendable {
        let destination: SidebarDestination
        let status: StatusFilterOption
        let subtag: String?
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

    actor Worker {
        private var query = LibraryQuery()

        func project(_ records: [MediaItem], request: Request) -> LibraryProjection? {
            guard !Task.isCancelled else { return nil }
            return query.project(records, request: request)
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
        let options: Options
    }

    private var sorted: (SortKey, [Int])?
    private var matches: (SearchKey, [Bool])?
    private var projected: (ProjectionKey, LibraryProjection)?

    mutating func project(_ records: [MediaItem], request: Request) -> LibraryProjection {
        let options = request.options
        let searchKey = SearchKey(revision: request.revision, notesRevision: request.notesRevision, text: options.text)
        let projectionKey = ProjectionKey(search: searchKey, options: options)
        if let (key, result) = projected, key == projectionKey {
            return result
        }

        let sortKey = SortKey(revision: request.sortRevision, field: options.sortField, ascending: options.ascending,
                              language: options.sortField == .title ? options.language : nil)
        if sorted?.0 != sortKey {
            sorted = (sortKey, Self.sortedIndices(records, key: sortKey))
        }
        let isSearching = !options.text.isEmpty
        if isSearching {
            if matches?.0 != searchKey {
                matches = (searchKey, Self.search(records, for: options.text))
            }
        } else {
            matches = nil
        }

        let usesShelves = options.status == .allShelves && !isSearching
        var statusCounts: [TrackingStatus: Int] = [:]
        var tagCounts: [String: Int] = [:]
        var shelves: [TrackingStatus: [LibraryPoster]] = [:]
        var flat: [LibraryPoster] = []
        var count = 0

        let category = options.destination.activeCategory
        let indexes = sorted?.1 ?? []
        let searchMatches = matches?.1
        for index in indexes {
            if let searchMatches, !searchMatches[index] { continue }
            let item = records[index]
            guard options.destination.includes(item) else { continue }
            let statusMatches = options.status == .allShelves || options.status == .single(item.status)
            let tag: String
            if category != nil || options.subtag != nil {
                tag = item.subtag.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                tag = ""
            }
            if category != nil, statusMatches, !tag.isEmpty {
                tagCounts[tag, default: 0] += 1
            }
            if let selectedTag = options.subtag, !selectedTag.isEmpty, tag != selectedTag { continue }
            statusCounts[item.status, default: 0] += 1
            guard statusMatches else { continue }

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
                                       subtags: tags, showStatusBadges: options.status == .allShelves && isSearching)
        projected = (projectionKey, result)
        return result
    }

    static func matches(_ item: MediaItem, text: String) -> Bool {
        guard !text.isEmpty else { return true }
        var matcher = SearchMatcher(text: text)
        return matcher.matches(item)
    }

    private static func search(_ records: [MediaItem], for text: String) -> [Bool] {
        var matcher = SearchMatcher(text: text)
        return records.map { matcher.matches($0) }
    }

    private struct SearchMatcher {
        let text: String
        let matchingCategories: Set<MediaCategory>
        var tagMatches: [String: Bool] = [:]

        init(text: String) {
            self.text = text
            matchingCategories = Set(MediaCategory.allCases.filter {
                $0.title(in: .zh).localizedCaseInsensitiveContains(text)
                    || $0.title(in: .en).localizedCaseInsensitiveContains(text)
            })
        }

        mutating func matches(_ item: MediaItem) -> Bool {
            if matchingCategories.contains(item.category)
                || item.title.localizedCaseInsensitiveContains(text)
                || item.titleEN.localizedCaseInsensitiveContains(text) {
                return true
            }
            if let cached = tagMatches[item.subtag] {
                return cached || item.notes.localizedCaseInsensitiveContains(text)
            }
            let match = item.subtag.localizedCaseInsensitiveContains(text)
                || MediaCategory.localizedSubtag(item.subtag, in: .en).localizedCaseInsensitiveContains(text)
                || MediaCategory.localizedSubtag(item.subtag, in: .zh).localizedCaseInsensitiveContains(text)
            tagMatches[item.subtag] = match
            return match || item.notes.localizedCaseInsensitiveContains(text)
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
        case .all: return true
        case .category(let category): return item.category == category
        case .fiveStar: return item.rating == 5
        }
    }
}
