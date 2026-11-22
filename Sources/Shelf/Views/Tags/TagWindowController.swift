import AppKit
import SwiftUI

private final class EscapeClosableWindow: NSWindow {
    var shouldCloseOnEscape: (() -> Bool)?

    override func cancelOperation(_ sender: Any?) {
        if shouldCloseOnEscape?() ?? true {
            close()
        }
    }
}

@MainActor
final class TagWindowController: NSObject, NSWindowDelegate {
    static let shared = TagWindowController()

    private var window: EscapeClosableWindow?
    private weak var store: LibraryStore?
    private nonisolated(unsafe) var windowCloseObserver: NSObjectProtocol?
    private var shouldCloseOnEscapeHandler: (() -> Bool)?

    private override init() {
        super.init()
    }

    deinit {
        if let windowCloseObserver {
            NotificationCenter.default.removeObserver(windowCloseObserver)
        }
    }

    func show(store: LibraryStore) {
        self.store = store
        installWindowObserverIfNeeded()

        if let existing = window {
            updateRootView(in: existing, store: store)
            existing.title = store.language.tr("管理标签", "Manage Tags")
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let created = EscapeClosableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 410, height: 520),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        created.isReleasedWhenClosed = false
        created.minSize = NSSize(width: 340, height: 380)
        created.title = store.language.tr("管理标签", "Manage Tags")
        created.delegate = self
        created.shouldCloseOnEscape = { [weak self] in
            self?.shouldCloseOnEscapeHandler?() ?? true
        }
        updateRootView(in: created, store: store)

        if let mainWindow = mainLibraryWindow(excluding: created) {
            let mainFrame = mainWindow.frame
            let size = created.frame.size
            created.setFrameOrigin(NSPoint(
                x: mainFrame.midX - size.width * 0.5,
                y: mainFrame.midY - size.height * 0.5
            ))
        } else {
            created.center()
        }

        self.window = created
        created.makeKeyAndOrderFront(nil)
    }

    func toggle(store: LibraryStore) {
        if let window, window.isVisible {
            window.close()
        } else {
            show(store: store)
        }
    }

    func focusMainLibraryWindow() {
        if let main = mainLibraryWindow(excluding: window) {
            main.makeKeyAndOrderFront(nil)
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        store?.isTagWindowKey = true
    }

    func windowDidResignKey(_ notification: Notification) {
        store?.isTagWindowKey = false
    }

    func windowWillClose(_ notification: Notification) {
        store?.isTagWindowKey = false
    }

    private func updateRootView(in window: EscapeClosableWindow, store: LibraryStore) {
        let rootView = TagManagerView(
            onFilterApplied: { [weak self] in
                self?.focusMainLibraryWindow()
            },
            onUpdateTitle: { [weak window] title in
                window?.title = title
            },
            registerEscapeHandler: { [weak self] handler in
                self?.shouldCloseOnEscapeHandler = handler
            }
        )
        .environment(store)

        if let hosting = window.contentView as? NSHostingView<AnyView> {
            hosting.rootView = AnyView(rootView)
        } else {
            window.contentView = NSHostingView(rootView: AnyView(rootView))
        }
    }

    private func isMainLibraryWindow(_ candidate: NSWindow, excluding excluded: [NSWindow?]) -> Bool {
        guard !excluded.contains(where: { $0 === candidate }) else { return false }
        return candidate.isVisible
            && candidate.canBecomeMain
            && !candidate.isSheet
            && candidate.level == .normal
    }

    private func mainLibraryWindow(excluding excluded: NSWindow?) -> NSWindow? {
        NSApp.windows.first { isMainLibraryWindow($0, excluding: [excluded]) }
    }

    private func installWindowObserverIfNeeded() {
        guard windowCloseObserver == nil else { return }
        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let closed = notification.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                guard let self, let tagWindow = self.window, closed !== tagWindow, tagWindow.isVisible else { return }
                let anotherMainRemains = NSApp.windows.contains {
                    self.isMainLibraryWindow($0, excluding: [tagWindow, closed])
                }
                if !anotherMainRemains && closed.canBecomeMain && !closed.isSheet && closed.level == .normal {
                    tagWindow.close()
                }
            }
        }
    }
}
