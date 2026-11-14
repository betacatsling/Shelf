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

    var body: some Scene {
        WindowGroup("作品库") {
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
                Button("添加作品…") {
                    showAddSheet = true
                }
                .keyboardShortcut("n", modifiers: [.command])

                Divider()

                Button("导出备份文件…") {
                    store.exportLibraryJSON()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])

                Button("导入备份文件…") {
                    store.importLibraryJSON()
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])

                Divider()

                Button("载入示例数据") {
                    store.restoreSampleItems()
                }

                Button("在访达中打开数据目录") {
                    let dir = CoverManager.shared.coversDirectory.deletingLastPathComponent()
                    NSWorkspace.shared.open(dir)
                }
            }

            CommandMenu("视图") {
                Button("全部") {
                    store.selectDestination(.all)
                }
                .keyboardShortcut("1", modifiers: [.command])

                Button("游戏") {
                    store.selectDestination(.category(.game))
                }
                .keyboardShortcut("2", modifiers: [.command])

                Button("文字") {
                    store.selectDestination(.category(.novel))
                }
                .keyboardShortcut("3", modifiers: [.command])

                Button("影像") {
                    store.selectDestination(.category(.video))
                }
                .keyboardShortcut("4", modifiers: [.command])

                Divider()

                Button("关闭右侧详情栏") {
                    store.selectedItemID = nil
                }
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(store.selectedItemID == nil)

                Divider()

                Button("放大海报") {
                    posterScale = min(1.36, posterScale + 0.08)
                }
                .keyboardShortcut("+", modifiers: [.command])

                Button("缩小海报") {
                    posterScale = max(0.78, posterScale - 0.08)
                }
                .keyboardShortcut("-", modifiers: [.command])

                Button("默认海报尺寸") {
                    posterScale = 1.0
                }
                .keyboardShortcut("0", modifiers: [.command])
            }
        }
    }
}
