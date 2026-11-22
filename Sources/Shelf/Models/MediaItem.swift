import Foundation
import SwiftUI

enum AppLanguage: String, Codable, CaseIterable, Identifiable {
    case zh = "zh"
    case en = "en"

    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .zh: return "中文"
        case .en: return "EN"
        }
    }

    var fullLabel: String {
        switch self {
        case .zh: return "简体中文"
        case .en: return "English"
        }
    }

    func tr(_ zh: String, _ en: String) -> String {
        self == .zh ? zh : en
    }
}

enum MediaCategory: String, Codable, CaseIterable, Identifiable {
    case game = "game"
    case novel = "novel"
    case video = "video"

    var id: String { rawValue }

    func title(in lang: AppLanguage = .zh) -> String {
        switch self {
        case .game: return lang.tr("游戏", "Games")
        case .novel: return lang.tr("文字", "Texts")
        case .video: return lang.tr("影像", "Videos")
        }
    }

    var systemImage: String {
        switch self {
        case .game: return "gamecontroller.fill"
        case .novel: return "book.closed.fill"
        case .video: return "film.stack.fill"
        }
    }

    var accentColor: Color {
        switch self {
        case .game: return Color(red: 0.28, green: 0.48, blue: 0.96)
        case .novel: return Color(red: 0.88, green: 0.53, blue: 0.22)
        case .video: return Color(red: 0.86, green: 0.30, blue: 0.45)
        }
    }

    /// Canonical storage values for starter tags (localized dynamically at display time)
    var presetTags: [String] {
        switch self {
        case .game:
            return ["Steam", "Switch", "PS5", "PC", "移动端"]
        case .novel:
            return ["小说", "非虚构", "社科", "文学", "漫画", "轻小说", "科幻"]
        case .video:
            return ["电影", "电视剧", "番剧", "纪录片", "动画电影"]
        }
    }

    static let defaultStarterTags: [String] = normalizeTags(allCases.flatMap(\.presetTags))

    private static let zhToEnTagMap: [String: String] = [
        "平台": "Platform",
        "体裁": "Genre",
        "形式": "Format",
        "移动端": "Mobile",
        "小说": "Novel",
        "非虚构": "Non-Fiction",
        "社科": "Social Science",
        "文学": "Literature",
        "漫画": "Manga",
        "轻小说": "Light Novel",
        "科幻": "Sci-Fi",
        "电影": "Movie",
        "电视剧": "TV Series",
        "番剧": "Anime",
        "纪录片": "Documentary",
        "动画电影": "Animated Film"
    ]

    private static let enToZhTagMap: [String: String] = {
        var reversed: [String: String] = [:]
        for (k, v) in zhToEnTagMap {
            reversed[v.lowercased()] = k
        }
        return reversed
    }()

    private static let canonicalTagLookup: [String: String] = {
        var lookup: [String: String] = [:]
        for tag in allCases.flatMap(\.presetTags) {
            lookup[tag.lowercased()] = tag
        }
        for (zh, en) in zhToEnTagMap {
            lookup[zh.lowercased()] = zh
            lookup[en.lowercased()] = zh
        }
        return lookup
    }()

    static func canonicalTag(_ rawTag: String) -> String {
        let trimmed = rawTag.trimmed
        guard !trimmed.isEmpty else { return "" }
        return canonicalTagLookup[trimmed.lowercased()] ?? trimmed
    }

    static func tagMatchKey(_ rawTag: String) -> String {
        canonicalTag(rawTag).folding(options: .caseInsensitive, locale: nil)
    }

    static func tagsMatch(_ lhs: String, _ rhs: String) -> Bool {
        let a = tagMatchKey(lhs)
        let b = tagMatchKey(rhs)
        return !a.isEmpty && a == b
    }

    static func normalizeTags(_ rawTags: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for raw in rawTags {
            let tag = canonicalTag(raw)
            guard !tag.isEmpty else { continue }
            let key = tagMatchKey(tag)
            if seen.insert(key).inserted {
                result.append(tag)
            }
        }
        return result
    }

    static func localizedTag(_ rawTag: String, in lang: AppLanguage) -> String {
        let trimmed = rawTag.trimmed
        guard !trimmed.isEmpty else { return "" }
        switch lang {
        case .zh:
            return enToZhTagMap[trimmed.lowercased()] ?? trimmed
        case .en:
            return zhToEnTagMap[trimmed] ?? trimmed
        }
    }

    func statusLabel(for status: TrackingStatus, in lang: AppLanguage = .zh) -> String {
        switch (self, status) {
        case (.game, .active): return lang.tr("正在玩", "Playing")
        case (.game, .completed): return lang.tr("已玩过", "Played")
        case (.game, .unfinished): return lang.tr("未完成", "Unfinished")
        case (.game, .backlog): return lang.tr("待玩", "Backlog")

        case (.novel, .active): return lang.tr("正在读", "Reading")
        case (.novel, .completed): return lang.tr("已读完", "Finished")
        case (.novel, .unfinished): return lang.tr("未完成", "Unfinished")
        case (.novel, .backlog): return lang.tr("待读", "To Read")

        case (.video, .active): return lang.tr("正在看", "Watching")
        case (.video, .completed): return lang.tr("已看完", "Watched")
        case (.video, .unfinished): return lang.tr("未完成", "Unfinished")
        case (.video, .backlog): return lang.tr("待看", "Watchlist")
        }
    }
}

enum TrackingStatus: String, Codable, CaseIterable, Identifiable {
    case active = "active"
    case completed = "completed"
    case unfinished = "unfinished"
    case backlog = "backlog"

    var id: String { rawValue }

    /// Display order in grouped shelf view: consistent with sidebar & filter tabs
    static var shelfOrder: [TrackingStatus] {
        [.active, .completed, .unfinished, .backlog]
    }

    /// Display order in filter tabs & forms: Active -> Completed -> Unfinished -> Backlog
    static var filterOrder: [TrackingStatus] {
        [.active, .completed, .unfinished, .backlog]
    }

    func genericTitle(in lang: AppLanguage = .zh) -> String {
        switch self {
        case .active: return lang.tr("进行中", "In Progress")
        case .completed: return lang.tr("已完成", "Completed")
        case .unfinished: return lang.tr("未完成", "Unfinished")
        case .backlog: return lang.tr("待开始", "Backlog")
        }
    }

    var systemImage: String {
        switch self {
        case .active: return "play.circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .unfinished: return "pause.circle.fill"
        case .backlog: return "bookmark.circle.fill"
        }
    }

    var tintRGB: RGBColor {
        switch self {
        case .active: return RGBColor(red: 0.20, green: 0.78, blue: 0.45)
        case .completed: return RGBColor(red: 0.34, green: 0.56, blue: 0.98)
        case .unfinished: return RGBColor(red: 0.92, green: 0.45, blue: 0.36)
        case .backlog: return RGBColor(red: 0.95, green: 0.68, blue: 0.22)
        }
    }

    var tintColor: Color {
        tintRGB.swiftUIColor
    }

    func localizedTitle(in category: MediaCategory?, lang: AppLanguage = .zh, compact: Bool = false) -> String {
        if let category {
            return category.statusLabel(for: self, in: lang)
        }
        if compact && lang == .en && self == .active {
            return "Active"
        }
        return genericTitle(in: lang)
    }
}

enum SidebarDestination: Hashable {
    case all
    case category(MediaCategory)
    case fiveStar
    case timeline

    static let allDestinations: [SidebarDestination] = [
        .all,
        .category(.game),
        .category(.novel),
        .category(.video),
        .fiveStar,
        .timeline
    ]

    var stableID: String {
        switch self {
        case .all: return "all"
        case .category(let cat): return "category:\(cat.rawValue)"
        case .fiveStar: return "fiveStar"
        case .timeline: return "timeline"
        }
    }

    func title(in lang: AppLanguage = .zh) -> String {
        switch self {
        case .all: return lang.tr("全部", "All")
        case .category(let cat): return cat.title(in: lang)
        case .fiveStar: return lang.tr("五星作品", "5-Star")
        case .timeline: return lang.tr("时间线", "Timeline")
        }
    }

    var systemImage: String {
        switch self {
        case .all: return "square.grid.2x2.fill"
        case .category(let cat): return cat.systemImage
        case .fiveStar: return "star.fill"
        case .timeline: return "calendar.day.timeline.left"
        }
    }

    var tintColor: Color {
        switch self {
        case .all: return .accentColor
        case .category(let cat): return cat.accentColor
        case .fiveStar: return ShelfTheme.starGold
        case .timeline: return Color(red: 0.44, green: 0.46, blue: 0.96)
        }
    }

    var activeCategory: MediaCategory? {
        if case .category(let cat) = self { return cat }
        return nil
    }

    var isTimeline: Bool {
        self == .timeline
    }
}

enum StatusFilterOption: Hashable {
    case allShelves
    case single(TrackingStatus)
}

enum LibrarySortField: String, CaseIterable, Identifiable {
    case updatedAt = "更新时间"
    case createdAt = "添加时间"
    case rating = "个人评分"
    case title = "作品名称"

    var id: String { rawValue }

    func menuTitle(in lang: AppLanguage) -> String {
        switch self {
        case .updatedAt: return lang.tr("按更新时间", "Date Updated")
        case .createdAt: return lang.tr("按添加时间", "Date Added")
        case .rating: return lang.tr("按个人评分", "Rating")
        case .title: return lang.tr("按作品名称", "Title")
        }
    }

    var defaultAscending: Bool {
        switch self {
        case .title: return true
        case .updatedAt, .createdAt, .rating: return false
        }
    }

    func descendingLabel(in lang: AppLanguage) -> String {
        switch self {
        case .updatedAt, .createdAt: return lang.tr("从新到旧", "Newest First")
        case .rating: return lang.tr("从高到低", "Highest First")
        case .title: return lang.tr("倒序（Z → A）", "Z → A")
        }
    }

    func ascendingLabel(in lang: AppLanguage) -> String {
        switch self {
        case .updatedAt, .createdAt: return lang.tr("从旧到新", "Oldest First")
        case .rating: return lang.tr("从低到高", "Lowest First")
        case .title: return lang.tr("正序（A → Z）", "A → Z")
        }
    }
}

struct MediaItem: Identifiable, Codable, Equatable, Hashable, Sendable {
    var id: UUID
    var title: String
    var titleEN: String
    var category: MediaCategory
    var status: TrackingStatus
    var tags: [String]
    var rating: Int // 0 = unrated, 1...5
    var notes: String
    var coverFileName: String?
    var paletteSeed: Int
    var startedAt: Date?
    var finishedAt: Date?
    var createdAt: Date
    var updatedAt: Date
    var isSample: Bool

    var hasTimelineDates: Bool {
        startedAt != nil || finishedAt != nil
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

    var subtag: String {
        get { tags.first ?? "" }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            tags = trimmed.isEmpty ? [] : MediaCategory.normalizeTags([trimmed])
        }
    }

    func hasTag(_ candidate: String) -> Bool {
        tags.contains { MediaCategory.tagsMatch($0, candidate) }
    }

    func hasAnyTag(in candidates: [String]) -> Bool {
        candidates.contains { hasTag($0) }
    }

    init(
        id: UUID = UUID(),
        title: String,
        titleEN: String = "",
        category: MediaCategory,
        status: TrackingStatus,
        subtag: String = "",
        tags: [String]? = nil,
        rating: Int = 0,
        notes: String = "",
        coverFileName: String? = nil,
        paletteSeed: Int = Int.random(in: 0..<1000),
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        isSample: Bool = false
    ) {
        self.id = id
        self.title = title
        self.titleEN = titleEN
        self.category = category
        self.status = status
        if let tags {
            self.tags = MediaCategory.normalizeTags(tags)
        } else {
            let trimmed = subtag.trimmingCharacters(in: .whitespacesAndNewlines)
            self.tags = trimmed.isEmpty ? [] : MediaCategory.normalizeTags([trimmed])
        }
        self.rating = min(max(rating, 0), 5)
        self.notes = notes
        self.coverFileName = coverFileName
        self.paletteSeed = paletteSeed
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isSample = isSample
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, titleEN, category, status, tags, subtag, rating, notes, coverFileName, paletteSeed, startedAt, finishedAt, createdAt, updatedAt, isSample
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.title = try container.decode(String.self, forKey: .title)
        self.titleEN = try container.decodeIfPresent(String.self, forKey: .titleEN) ?? ""
        self.category = try container.decode(MediaCategory.self, forKey: .category)
        self.status = try container.decode(TrackingStatus.self, forKey: .status)
        if let decodedTags = try container.decodeIfPresent([String].self, forKey: .tags) {
            self.tags = MediaCategory.normalizeTags(decodedTags)
        } else {
            let decodedSubtag = try container.decodeIfPresent(String.self, forKey: .subtag) ?? ""
            let trimmed = decodedSubtag.trimmingCharacters(in: .whitespacesAndNewlines)
            self.tags = trimmed.isEmpty ? [] : MediaCategory.normalizeTags([trimmed])
        }
        let rawRating = try container.decodeIfPresent(Int.self, forKey: .rating) ?? 0
        self.rating = min(max(rawRating, 0), 5)
        self.notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
        self.coverFileName = try container.decodeIfPresent(String.self, forKey: .coverFileName)
        self.paletteSeed = try container.decodeIfPresent(Int.self, forKey: .paletteSeed) ?? 0
        self.startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        self.finishedAt = try container.decodeIfPresent(Date.self, forKey: .finishedAt)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        self.isSample = try container.decodeIfPresent(Bool.self, forKey: .isSample) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let normalizedTags = MediaCategory.normalizeTags(tags)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(titleEN, forKey: .titleEN)
        try container.encode(category, forKey: .category)
        try container.encode(status, forKey: .status)
        try container.encode(normalizedTags, forKey: .tags)
        try container.encode(normalizedTags.first ?? "", forKey: .subtag)
        try container.encode(rating, forKey: .rating)
        try container.encode(notes, forKey: .notes)
        try container.encodeIfPresent(coverFileName, forKey: .coverFileName)
        try container.encode(paletteSeed, forKey: .paletteSeed)
        try container.encodeIfPresent(startedAt, forKey: .startedAt)
        try container.encodeIfPresent(finishedAt, forKey: .finishedAt)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(isSample, forKey: .isSample)
    }

    /// Returns the localized title in the active language, seamlessly falling back if an official translation does not exist.
    func displayTitle(in lang: AppLanguage) -> String {
        let preferred = (lang == .zh ? title : titleEN).trimmingCharacters(in: .whitespacesAndNewlines)
        return preferred.isEmpty
            ? (lang == .zh ? titleEN : title).trimmingCharacters(in: .whitespacesAndNewlines)
            : preferred
    }

    func quotedTitle(in lang: AppLanguage) -> String {
        let name = displayTitle(in: lang)
        return lang == .zh ? "《\(name)》" : "“\(name)”"
    }

    /// Returns the counterpart language title if both Chinese and English titles exist and differ.
    func secondaryTitle(in lang: AppLanguage) -> String? {
        let zh = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let en = titleEN.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !zh.isEmpty, !en.isEmpty, zh.caseInsensitiveCompare(en) != .orderedSame else {
            return nil
        }
        return lang == .zh ? en : zh
    }
}

struct SearchTagToken: Identifiable, Hashable, Sendable {
    let tag: String

    init(tag: String) {
        self.tag = MediaCategory.canonicalTag(tag)
    }

    var id: String { MediaCategory.tagMatchKey(tag) }

    static func == (lhs: SearchTagToken, rhs: SearchTagToken) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
