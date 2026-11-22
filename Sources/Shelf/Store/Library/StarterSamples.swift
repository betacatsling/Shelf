import Foundation

extension LibraryStore {
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
