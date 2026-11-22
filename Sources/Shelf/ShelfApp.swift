import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var terminateSignal: DispatchSourceSignal?
    var flushLibrary: (() throws -> Void)?
    var language: (() -> AppLanguage)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The library CLI requests termination with SIGTERM before editing the JSON.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { NSApplication.shared.terminate(nil) }
        }
        source.resume()
        terminateSignal = source
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        do {
            try flushLibrary?()
            return .terminateNow
        } catch {
            let lang = language?() ?? .zh
            let alert = NSAlert(error: error)
            alert.messageText = lang.tr("无法保存作品库", "Could Not Save Library")
            alert.addButton(withTitle: lang.tr("返回作品库", "Return to Shelf"))
            alert.runModal()
            return .terminateCancel
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct ShelfApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = LibraryStore()
    @State private var updater = AppUpdater()
    @State private var showAddSheet = false
    @AppStorage(PosterScaleConfig.storageKey) private var posterScale: Double = PosterScaleConfig.defaultScale
    @AppStorage(TimelineZoomConfig.storageKey) private var timelineZoom: Double = TimelineZoomConfig.defaultZoom

    private var lang: AppLanguage { store.language }

    var body: some Scene {
        WindowGroup(lang.tr("作品库", "Shelf")) {
            MainWindowView(showAddSheet: $showAddSheet)
                .environment(store)
                .environment(updater)
                .frame(minWidth: 920, minHeight: 580)
                .onAppear {
                    let currentStore = store
                    appDelegate.flushLibrary = { [weak currentStore] in
                        try currentStore?.flushPendingChanges()
                    }
                    appDelegate.language = { [weak currentStore] in currentStore?.language ?? .zh }
                    updater.onToast = { [weak currentStore] message in
                        currentStore?.showToast(message)
                    }
                    updater.languageProvider = { [weak currentStore] in
                        currentStore?.language ?? .zh
                    }
                    updater.flushBeforeQuit = { [weak currentStore] in
                        try currentStore?.flushPendingChanges()
                    }
                    updater.startAutomaticChecksIfNeeded()
                }
        }
        .defaultSize(width: 1200, height: 780)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(after: .appInfo) {
                Button(
                    updater.availableUpdate.map { update in
                        lang.tr("更新至 \(update.displayTag)…", "Update to \(update.displayTag)…")
                    } ?? lang.tr("检查更新…", "Check for Updates…")
                ) {
                    if updater.availableUpdate != nil {
                        updater.performUpdate()
                    } else {
                        updater.checkForUpdates(userInitiated: true)
                    }
                }
                .disabled(updater.isBusy)
            }

            CommandGroup(replacing: .newItem) {
                Button(lang.tr("添加作品…", "New Item…")) {
                    showAddSheet = true
                }
                .disabled(!store.isReady)
                .keyboardShortcut("n", modifiers: [.command])

                Divider()

                Button(lang.tr("导出备份文件…", "Export Backup…")) {
                    store.exportLibraryJSON()
                }
                .disabled(!store.isReady)
                .keyboardShortcut("e", modifiers: [.command, .shift])

                Button(lang.tr("导入备份文件…", "Import Backup…")) {
                    store.importLibraryJSON()
                }
                .disabled(!store.isReady)
                .keyboardShortcut("i", modifiers: [.command, .shift])

                Divider()

                Button(lang.tr("载入示例数据", "Load Sample Data")) {
                    store.restoreSampleItems()
                }
                .disabled(!store.isReady)

                Button(lang.tr("在访达中打开数据目录", "Show Data Folder in Finder")) {
                    let dir = CoverManager.shared.coversDirectory.deletingLastPathComponent()
                    NSWorkspace.shared.open(dir)
                }
            }

            CommandMenu(lang.tr("视图", "View")) {
                Button(lang.tr("快速查找…", "Quick Find…")) {
                    TagWindowController.shared.focusMainLibraryWindow()
                    store.tagPickerItemID = nil
                    store.isQuickFindPresented = true
                }
                .keyboardShortcut("f", modifiers: [.command])
                .disabled(!store.isReady)

                Button(lang.tr("设置作品标签…", "Tags…")) {
                    TagWindowController.shared.focusMainLibraryWindow()
                    store.isQuickFindPresented = false
                    store.tagPickerItemID = store.selectedItemID
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(!store.isReady || store.selectedItemID == nil)

                Divider()

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

                Button(SidebarDestination.fiveStar.title(in: lang)) {
                    store.selectDestination(.fiveStar)
                }
                .keyboardShortcut("5", modifiers: [.command])

                Button(SidebarDestination.timeline.title(in: lang)) {
                    store.selectDestination(.timeline)
                }
                .keyboardShortcut("6", modifiers: [.command])

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
                .disabled(
                    store.selectedItemID == nil
                        || store.isQuickFindPresented
                        || store.tagPickerItemID != nil
                        || store.isDetailPopoverPresented
                        || store.isTagWindowKey
                )

                Button(lang.tr("清除筛选", "Clear Filter")) {
                    store.clearSearch()
                }
                .keyboardShortcut(.escape, modifiers: [.control])
                .disabled(!store.hasActiveFilter)

                Divider()

                Button(store.selectedDestination.isTimeline ? lang.tr("拉近时间轴", "Zoom In Timeline") : lang.tr("放大海报", "Zoom In")) {
                    if store.selectedDestination.isTimeline {
                        timelineZoom = TimelineZoomConfig.zoomIn(from: timelineZoom)
                    } else {
                        posterScale = PosterScaleConfig.zoomIn(from: posterScale)
                    }
                }
                .keyboardShortcut("+", modifiers: [.command])

                Button(store.selectedDestination.isTimeline ? lang.tr("拉远时间轴", "Zoom Out Timeline") : lang.tr("缩小海报", "Zoom Out")) {
                    if store.selectedDestination.isTimeline {
                        timelineZoom = TimelineZoomConfig.zoomOut(from: timelineZoom)
                    } else {
                        posterScale = PosterScaleConfig.zoomOut(from: posterScale)
                    }
                }
                .keyboardShortcut("-", modifiers: [.command])

                Button(store.selectedDestination.isTimeline ? lang.tr("默认时间轴缩放", "Reset Timeline Zoom") : lang.tr("默认海报尺寸", "Actual Size")) {
                    if store.selectedDestination.isTimeline {
                        timelineZoom = TimelineZoomConfig.defaultZoom
                    } else {
                        posterScale = PosterScaleConfig.defaultScale
                    }
                }
                .keyboardShortcut("0", modifiers: [.command])
            }

            CommandGroup(after: .windowArrangement) {
                Button(lang.tr("标签", "Tags")) {
                    TagWindowController.shared.toggle(store: store)
                }
                .keyboardShortcut("t", modifiers: [.command, .control])
                .disabled(!store.isReady)
            }
        }
    }
}
