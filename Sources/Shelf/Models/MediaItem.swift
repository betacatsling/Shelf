import Foundation
import SwiftUI

enum MediaCategory: String, Codable, CaseIterable, Identifiable {
    case game = "game"
    case novel = "novel"
    case video = "video"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .game: return "游戏"
        case .novel: return "文字"
        case .video: return "影像"
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

    var subtagFieldTitle: String {
        switch self {
        case .game: return "游玩平台（可选）"
        case .novel: return "文字体裁（可选）"
        case .video: return "影像类型（可选）"
        }
    }

    var subtagShortLabel: String {
        switch self {
        case .game: return "平台"
        case .novel: return "体裁"
        case .video: return "类型"
        }
    }

    var presetTags: [String] {
        switch self {
        case .game:
            return ["Steam", "Switch", "PS5", "PC", "移动端"]
        case .novel:
            return ["小说", "非虚构", "社科", "文学", "漫画", "轻小说"]
        case .video:
            return ["电影", "电视剧", "番剧", "纪录片", "动画电影"]
        }
    }

    func statusLabel(for status: TrackingStatus) -> String {
        switch (self, status) {
        case (.game, .active): return "正在玩"
        case (.game, .completed): return "已玩过"
        case (.game, .unfinished): return "未完成"
        case (.game, .backlog): return "待玩"

        case (.novel, .active): return "正在读"
        case (.novel, .completed): return "已读完"
        case (.novel, .unfinished): return "未完成"
        case (.novel, .backlog): return "待读"

        case (.video, .active): return "正在看"
        case (.video, .completed): return "已看完"
        case (.video, .unfinished): return "未完成"
        case (.video, .backlog): return "待看"
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

    var genericTitle: String {
        switch self {
        case .active: return "进行中"
        case .completed: return "已完成"
        case .unfinished: return "未完成"
        case .backlog: return "待开始"
        }
    }

    var subtitle: String {
        switch self {
        case .active: return "当前正在进行"
        case .completed: return "已通关或已看完"
        case .unfinished: return "曾开始但尚未完成"
        case .backlog: return "计划体验但尚未开始"
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

    var tintColor: Color {
        switch self {
        case .active: return Color(red: 0.20, green: 0.78, blue: 0.45)
        case .completed: return Color(red: 0.34, green: 0.56, blue: 0.98)
        case .unfinished: return Color(red: 0.92, green: 0.45, blue: 0.36)
        case .backlog: return Color(red: 0.95, green: 0.68, blue: 0.22)
        }
    }

    func localizedTitle(in category: MediaCategory?) -> String {
        if let category {
            return category.statusLabel(for: self)
        }
        return genericTitle
    }
}

enum SidebarDestination: Hashable {
    case all
    case category(MediaCategory)
    case status(TrackingStatus)
    case fiveStar

    var title: String {
        switch self {
        case .all: return "全部"
        case .category(let cat): return cat.title
        case .status(let status): return status.genericTitle
        case .fiveStar: return "五星作品"
        }
    }

    var activeCategory: MediaCategory? {
        if case .category(let cat) = self { return cat }
        return nil
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

    var menuTitle: String {
        "按\(rawValue)"
    }

    var defaultAscending: Bool {
        switch self {
        case .title: return true
        case .updatedAt, .createdAt, .rating: return false
        }
    }

    var descendingLabel: String {
        switch self {
        case .updatedAt, .createdAt: return "从新到旧"
        case .rating: return "从高到低"
        case .title: return "倒序（Z → A）"
        }
    }

    var ascendingLabel: String {
        switch self {
        case .updatedAt, .createdAt: return "从旧到新"
        case .rating: return "从低到高"
        case .title: return "正序（A → Z）"
        }
    }
}

struct MediaItem: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var title: String
    var category: MediaCategory
    var status: TrackingStatus
    var subtag: String
    var rating: Int // 0 = unrated, 1...5
    var notes: String
    var coverFileName: String?
    var paletteSeed: Int
    var createdAt: Date
    var updatedAt: Date
    var isSample: Bool

    init(
        id: UUID = UUID(),
        title: String,
        category: MediaCategory,
        status: TrackingStatus,
        subtag: String = "",
        rating: Int = 0,
        notes: String = "",
        coverFileName: String? = nil,
        paletteSeed: Int = Int.random(in: 0..<1000),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        isSample: Bool = false
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.status = status
        self.subtag = subtag
        self.rating = min(max(rating, 0), 5)
        self.notes = notes
        self.coverFileName = coverFileName
        self.paletteSeed = paletteSeed
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isSample = isSample
    }
}
