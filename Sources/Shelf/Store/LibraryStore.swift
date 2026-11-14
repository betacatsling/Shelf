import AppKit
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class LibraryStore {
    var language: AppLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: "shelf.language") }
    }
    var selectedDestination: SidebarDestination = .all
    var statusFilter: StatusFilterOption = .allShelves
    var subtagFilter: String?
    var sortField: LibrarySortField = .updatedAt
    var sortAscending = false
    var searchText = ""
    var selectedItemID: UUID? {
        didSet { refreshSelectedItem() }
    }
    private(set) var selectedItem: MediaItem?
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
                let items = try await file.load()
                guard let self else { return }
                replaceRecords(with: items ?? Self.makeStarterSamples())
                isLoading = false
                if items == nil { scheduleSave() }
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
        replaceRecords(with: previewItems)
    }

    var isReady: Bool { !isLoading && !loadFailed }
    var isEmpty: Bool { counts.total == 0 }
    var hasSampleItems: Bool { counts.samples > 0 }

    func item(withID id: UUID) -> MediaItem? {
        indices[id].map { records[$0] }
    }

    private func refreshSelectedItem() {
        let item = selectedItemID.flatMap(item(withID:))
        if selectedItem != item { selectedItem = item }
    }

    func toggleLanguage() {
        withAnimation(.snappy(duration: 0.16)) {
            language = (language == .zh) ? .en : .zh
        }
    }

    func selectDestination(_ destination: SidebarDestination) {
        selectedDestination = destination
        statusFilter = .allShelves
        subtagFilter = nil
        if let item = selectedItem,
           !destination.includes(item) || !LibraryQuery.matches(item, text: trimmedSearchText) {
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
                                    subtag: subtagFilter, text: text, sortField: sortField,
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
        newItem.createdAt = Date()
        newItem.updatedAt = newItem.createdAt
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
        if item.coverFileName == originalCoverFileName {
            item.coverFileName = records[index].coverFileName
        } else {
            coverImports.removeValue(forKey: updated.id)?.cancel()
        }
        if touchTimestamp { item.updatedAt = Date() }
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
        replaceRecords(with: records + Self.makeStarterSamples())
        scheduleSave()
        showToast(language.tr("已载入示例数据", "Loaded sample data"))
    }

    func showToast(_ message: String) {
        toastTask?.cancel()
        withAnimation(.easeOut(duration: 0.20)) {
            toastMessage = message
        }
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(2200))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.20)) {
                self?.toastMessage = nil
            }
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
        libraryFile.save(records) { [weak self] result in
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
        try libraryFile.flush(records)
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
