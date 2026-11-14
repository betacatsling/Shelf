import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var onTerminate: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        onTerminate?()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct ShelfApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = LibraryStore()
    @State private var showAddSheet = false
    @AppStorage("shelf.posterScale") private var posterScale: Double = 1.0

    private var lang: AppLanguage { store.language }

    var body: some Scene {
        WindowGroup(lang.tr("作品库", "Shelf")) {
            MainWindowView(showAddSheet: $showAddSheet)
                .environmentObject(store)
                .frame(minWidth: 920, minHeight: 580)
                .onAppear {
                    let currentStore = store
                    appDelegate.onTerminate = { [weak currentStore] in
                        currentStore?.saveImmediately()
                    }
                }
        }
        .defaultSize(width: 1200, height: 780)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(lang.tr("添加作品…", "New Item…")) {
                    showAddSheet = true
                }
                .keyboardShortcut("n", modifiers: [.command])

                Divider()

                Button(lang.tr("导出备份文件…", "Export Backup…")) {
                    store.exportLibraryJSON()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])

                Button(lang.tr("导入备份文件…", "Import Backup…")) {
                    store.importLibraryJSON()
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])

                Divider()

                Button(lang.tr("载入示例数据", "Load Sample Data")) {
                    store.restoreSampleItems()
                }

                Button(lang.tr("在访达中打开数据目录", "Show Data Folder in Finder")) {
                    let dir = CoverManager.shared.coversDirectory.deletingLastPathComponent()
                    NSWorkspace.shared.open(dir)
                }
            }

            CommandMenu(lang.tr("视图", "View")) {
                Button(SidebarDestination.all.title(in: lang)) {
                    store.selectDestination(.all)
                }
                .keyboardShortcut("1", modifiers: [.command])

                Button(MediaCategory.game.title(in: lang)) {
                    store.selectDestination(.category(.game))
                }
                .keyboardShortcut("2", modifiers: [.command])

                Button(MediaCategory.novel.title(in: lang)) {
                    store.selectDestination(.category(.novel))
                }
                .keyboardShortcut("3", modifiers: [.command])

                Button(MediaCategory.video.title(in: lang)) {
                    store.selectDestination(.category(.video))
                }
                .keyboardShortcut("4", modifiers: [.command])

                Divider()

                Button(lang.tr("切换为英文 (English)", "Switch to 中文")) {
                    store.toggleLanguage()
                }
                .keyboardShortcut("l", modifiers: [.command])

                Divider()

                Button(lang.tr("关闭右侧详情栏", "Hide Details")) {
                    store.selectedItemID = nil
                }
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(store.selectedItemID == nil)

                Divider()

                Button(lang.tr("放大海报", "Zoom In")) {
                    posterScale = min(1.36, posterScale + 0.08)
                }
                .keyboardShortcut("+", modifiers: [.command])

                Button(lang.tr("缩小海报", "Zoom Out")) {
                    posterScale = max(0.78, posterScale - 0.08)
                }
                .keyboardShortcut("-", modifiers: [.command])

                Button(lang.tr("默认海报尺寸", "Actual Size")) {
                    posterScale = 1.0
                }
                .keyboardShortcut("0", modifiers: [.command])
            }
        }
    }
}
