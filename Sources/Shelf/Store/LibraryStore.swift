import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var items: [MediaItem] = [] {
        didSet { invalidateFilterCache() }
    }
    @Published var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: "shelf.language")
            invalidateFilterCache()
        }
    }
    @Published var selectedDestination: SidebarDestination = .all {
        didSet { invalidateFilterCache() }
    }
    @Published var statusFilter: StatusFilterOption = .allShelves {
        didSet { invalidateFilterCache() }
    }
    @Published var categoryFilter: MediaCategory? = nil {
        didSet { invalidateFilterCache() }
    }
    @Published var subtagFilter: String? = nil {
        didSet { invalidateFilterCache() }
    }
    @Published var sortField: LibrarySortField = .updatedAt {
        didSet { invalidateFilterCache() }
    }
    @Published var sortAscending: Bool = false {
        didSet { invalidateFilterCache() }
    }
    @Published var searchText: String = "" {
        didSet { invalidateFilterCache() }
    }
    @Published var selectedItemID: UUID? = nil
    @Published var toastMessage: String? = nil

    private let storageURL: URL?
    private var saveTask: Task<Void, Never>? = nil
    private var cachedDefaultFilteredItems: [MediaItem]? = nil

    private func invalidateFilterCache() {
        cachedDefaultFilteredItems = nil
    }

    init() {
        let savedLang = UserDefaults.standard.string(forKey: "shelf.language") ?? "zh"
        self.language = AppLanguage(rawValue: savedLang) ?? .zh

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let baseDir = appSupport.appendingPathComponent("Shelf", isDirectory: true)
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        self.storageURL = baseDir.appendingPathComponent("library.json")

        load()
    }

    /// In-memory initializer for UI previews/snapshots (never reads or writes user's disk data).
    init(previewItems: [MediaItem]? = nil, language: AppLanguage = .zh) {
        self.language = language
        self.storageURL = nil
        self.items = previewItems ?? Self.makeStarterSamples()
    }

    func toggleLanguage() {
        withAnimation(.snappy(duration: 0.16)) {
            language = (language == .zh) ? .en : .zh
        }
    }

    var selectedItem: MediaItem? {
        guard let selectedItemID else { return nil }
        return items.first(where: { $0.id == selectedItemID })
    }

    var hasSampleItems: Bool {
        items.contains(where: \.isSample)
    }

    func selectDestination(_ destination: SidebarDestination) {
        selectedDestination = destination
        statusFilter = .allShelves
        categoryFilter = nil
        subtagFilter = nil
        if let currentID = selectedItemID {
            let stillVisible = filteredItems().contains(where: { $0.id == currentID })
            if !stillVisible {
                selectedItemID = nil
            }
        }
    }

    // MARK: - Counts

    func count(for destination: SidebarDestination) -> Int {
        switch destination {
        case .all:
            return items.count
        case .category(let cat):
            return items.reduce(0) { $0 + ($1.category == cat ? 1 : 0) }
        case .status(let status):
            return items.reduce(0) { $0 + ($1.status == status ? 1 : 0) }
        case .fiveStar:
            return items.reduce(0) { $0 + ($1.rating == 5 ? 1 : 0) }
        }
    }

    // MARK: - Filtering & Sorting

    var availableSubtagsInCurrentView: [String] {
        let base = baseFilteredItems(ignoreSubtag: true, ignoreStatusTab: false)
        var counts: [String: Int] = [:]
        for item in base {
            let trimmed = item.subtag.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                counts[trimmed, default: 0] += 1
            }
        }
        return counts.keys.sorted { lhs, rhs in
            if counts[lhs] != counts[rhs] {
                return (counts[lhs] ?? 0) > (counts[rhs] ?? 0)
            }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }

    func filteredItems(overrideStatus: TrackingStatus? = nil) -> [MediaItem] {
        if overrideStatus == nil, let cached = cachedDefaultFilteredItems {
            return cached
        }
        var result = baseFilteredItems(ignoreSubtag: false, ignoreStatusTab: overrideStatus != nil)
        if let overrideStatus {
            result = result.filter { $0.status == overrideStatus }
            return sortItems(result)
        }
        let sorted = sortItems(result)
        cachedDefaultFilteredItems = sorted
        return sorted
    }

    private func baseFilteredItems(ignoreSubtag: Bool, ignoreStatusTab: Bool) -> [MediaItem] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        return items.filter { item in
            switch selectedDestination {
            case .all:
                break
            case .category(let cat):
                if item.category != cat { return false }
            case .status(let status):
                if item.status != status { return false }
            case .fiveStar:
                if item.rating < 5 { return false }
            }

            if selectedDestination.isStatusLocked {
                if let categoryFilter, item.category != categoryFilter {
                    return false
                }
            } else if !ignoreStatusTab, case .single(let filterStatus) = statusFilter {
                if item.status != filterStatus {
                    return false
                }
            }

            if !ignoreSubtag, let subtagFilter, !subtagFilter.isEmpty {
                if item.subtag.trimmingCharacters(in: .whitespacesAndNewlines) != subtagFilter {
                    return false
                }
            }

            if !q.isEmpty {
                let matchTitleZH = item.title.localizedCaseInsensitiveContains(q)
                let matchTitleEN = item.titleEN.localizedCaseInsensitiveContains(q)
                let matchTagRaw = item.subtag.localizedCaseInsensitiveContains(q)
                let matchTagEN = MediaCategory.localizedSubtag(item.subtag, in: .en).localizedCaseInsensitiveContains(q)
                let matchTagZH = MediaCategory.localizedSubtag(item.subtag, in: .zh).localizedCaseInsensitiveContains(q)
                let matchNotes = item.notes.localizedCaseInsensitiveContains(q)
                let matchCatZH = item.category.title(in: .zh).localizedCaseInsensitiveContains(q)
                let matchCatEN = item.category.title(in: .en).localizedCaseInsensitiveContains(q)
                if !(matchTitleZH || matchTitleEN || matchTagRaw || matchTagEN || matchTagZH || matchNotes || matchCatZH || matchCatEN) {
                    return false
                }
            }

            return true
        }
    }

    private static let pinyinLocale = Locale(identifier: "zh-Hans-CN")
    private static let englishLocale = Locale(identifier: "en_US")

    func selectSortField(_ field: LibrarySortField) {
        if sortField == field {
            sortAscending.toggle()
        } else {
            sortField = field
            sortAscending = field.defaultAscending
        }
    }

    private func sortItems(_ list: [MediaItem]) -> [MediaItem] {
        switch sortField {
        case .updatedAt:
            return list.sorted {
                if $0.updatedAt != $1.updatedAt {
                    return sortAscending ? ($0.updatedAt < $1.updatedAt) : ($0.updatedAt > $1.updatedAt)
                }
                return $0.createdAt > $1.createdAt
            }

        case .createdAt:
            return list.sorted {
                if $0.createdAt != $1.createdAt {
                    return sortAscending ? ($0.createdAt < $1.createdAt) : ($0.createdAt > $1.createdAt)
                }
                return $0.updatedAt > $1.updatedAt
            }

        case .rating:
            return list.sorted {
                let lhsRated = $0.rating > 0
                let rhsRated = $1.rating > 0
                if lhsRated != rhsRated {
                    return lhsRated
                }
                if $0.rating != $1.rating {
                    return sortAscending ? ($0.rating < $1.rating) : ($0.rating > $1.rating)
                }
                return $0.updatedAt > $1.updatedAt
            }

        case .title:
            let activeLang = language
            let collateLocale = (activeLang == .zh) ? Self.pinyinLocale : Self.englishLocale
            return list.sorted {
                let lhsName = $0.displayTitle(in: activeLang)
                let rhsName = $1.displayTitle(in: activeLang)
                let cmp = lhsName.compare(
                    rhsName,
                    options: [.caseInsensitive, .numeric, .widthInsensitive],
                    range: nil,
                    locale: collateLocale
                )
                if cmp != .orderedSame {
                    return sortAscending ? (cmp == .orderedAscending) : (cmp == .orderedDescending)
                }
                return $0.updatedAt > $1.updatedAt
            }
        }
    }

    // MARK: - CRUD Operations

    @discardableResult
    func addItem(_ item: MediaItem) -> MediaItem {
        var newItem = item
        newItem.createdAt = Date()
        newItem.updatedAt = Date()
        items.insert(newItem, at: 0)
        saveImmediately()
        let quoted = newItem.quotedTitle(in: language)
        showToast(language.tr("已添加\(quoted)", "Added \(quoted)"))
        return newItem
    }

    func updateItem(_ updated: MediaItem, touchTimestamp: Bool = true) {
        guard let idx = items.firstIndex(where: { $0.id == updated.id }) else { return }
        var copy = updated
        if touchTimestamp {
            copy.updatedAt = Date()
        }
        items[idx] = copy
        saveImmediately()
    }

    func updateStatus(for id: UUID, to status: TrackingStatus) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        guard items[idx].status != status else { return }
        let cat = items[idx].category
        items[idx].status = status
        items[idx].updatedAt = Date()
        saveImmediately()
        let quoted = items[idx].quotedTitle(in: language)
        let stLabel = cat.statusLabel(for: status, in: language)
        showToast(language.tr("\(quoted)已移至「\(stLabel)」", "Moved \(quoted) to \(stLabel)"))
    }

    func updateRating(for id: UUID, rating: Int) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        let clamped = min(max(rating, 0), 5)
        guard items[idx].rating != clamped else { return }
        items[idx].rating = clamped
        items[idx].updatedAt = Date()
        saveImmediately()
    }

    /// Updates notes without mutating `updatedAt` on every keystroke (prevents shelf cards jumping mid-typing)
    /// and coalesces disk writes.
    func updateNotes(for id: UUID, notes: String) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        guard items[idx].notes != notes else { return }
        items[idx].notes = notes
        scheduleDebouncedSave()
    }

    func updateCover(for id: UUID, newCoverFileName: String?) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        let oldCover = items[idx].coverFileName
        guard oldCover != newCoverFileName else { return }
        CoverManager.shared.removeCover(fileName: oldCover)
        items[idx].coverFileName = newCoverFileName
        saveImmediately()
        let quoted = items[idx].quotedTitle(in: language)
        if newCoverFileName != nil {
            showToast(language.tr("已更换\(quoted)的封面", "Updated cover for \(quoted)"))
        } else {
            showToast(language.tr("已恢复\(quoted)的默认封面", "Reset cover for \(quoted)"))
        }
    }

    func deleteItem(id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        let removed = items.remove(at: idx)
        CoverManager.shared.removeCover(fileName: removed.coverFileName)
        if selectedItemID == id {
            selectedItemID = nil
        }
        saveImmediately()
        let quoted = removed.quotedTitle(in: language)
        showToast(language.tr("已删除\(quoted)", "Deleted \(quoted)"))
    }

    func clearSampleItems() {
        let samples = items.filter(\.isSample)
        for sample in samples {
            CoverManager.shared.removeCover(fileName: sample.coverFileName)
            if selectedItemID == sample.id {
                selectedItemID = nil
            }
        }
        items.removeAll(where: \.isSample)
        saveImmediately()
        showToast(language.tr("已清空示例数据", "Cleared sample data"))
    }

    func restoreSampleItems() {
        let samples = Self.makeStarterSamples()
        items.append(contentsOf: samples)
        saveImmediately()
        showToast(language.tr("已载入示例数据", "Loaded sample data"))
    }

    func showToast(_ message: String) {
        withAnimation(.easeOut(duration: 0.20)) {
            toastMessage = message
        }
        let captured = message
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if self.toastMessage == captured {
                withAnimation(.easeOut(duration: 0.20)) {
                    self.toastMessage = nil
                }
            }
        }
    }

    // MARK: - Persistence & Backup

    private func load() {
        guard let storageURL else { return }
        if FileManager.default.fileExists(atPath: storageURL.path) {
            do {
                let data = try Data(contentsOf: storageURL)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                self.items = try decoder.decode([MediaItem].self, from: data)
                CoverManager.shared.preloadThumbnails(for: self.items.compactMap(\.coverFileName))
                return
            } catch {
                print("Failed to decode library.json: \(error)")
            }
        }
        self.items = Self.makeStarterSamples()
        saveImmediately()
    }

    private func scheduleDebouncedSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self.saveImmediately()
        }
    }

    func saveImmediately() {
        saveTask?.cancel()
        saveTask = nil
        guard let storageURL else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(items)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            print("Failed to save library.json: \(error)")
        }
    }

    func exportLibraryJSON() {
        let panel = NSSavePanel()
        panel.title = language.tr("导出备份文件", "Export Backup File")
        panel.nameFieldStringValue = language.tr("作品库备份.json", "Shelf-Backup.json")
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(items)
            try data.write(to: url, options: .atomic)
            showToast(language.tr("数据已导出", "Backup exported"))
        } catch {
            showToast(language.tr("导出失败：\(error.localizedDescription)", "Export failed: \(error.localizedDescription)"))
        }
    }

    func importLibraryJSON() {
        let panel = NSOpenPanel()
        panel.title = language.tr("导入备份文件", "Import Backup File")
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let imported = try decoder.decode([MediaItem].self, from: data)
            var existingIDs = Set(items.map(\.id))
            var addedCount = 0
            for entry in imported where !existingIDs.contains(entry.id) {
                items.append(entry)
                existingIDs.insert(entry.id)
                addedCount += 1
            }
            saveImmediately()
            CoverManager.shared.preloadThumbnails(for: items.compactMap(\.coverFileName))
            showToast(language.tr("已成功导入 \(addedCount) 条记录", "Imported \(addedCount) items"))
        } catch {
            showToast(language.tr("导入失败：文件格式不兼容", "Import failed: incompatible file format"))
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
