import AppKit
import Foundation
import UniformTypeIdentifiers

extension LibraryStore {
    func exportLibraryJSON() {
        guard isReady else { return }
        let panel = NSSavePanel()
        panel.title = language.tr("导出备份文件", "Export Backup File")
        panel.nameFieldStringValue = language.tr("作品库备份.json", "Shelf-Backup.json")
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let items = snapshotRecords()

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
                let addedCount = appendImportedItems(imported)
                showToast(language.tr("已成功导入 \(addedCount) 条记录", "Imported \(addedCount) items"))
            } catch {
                showToast(language.tr("导入失败：文件格式不兼容", "Import failed: incompatible file format"))
            }
        }
    }
}
