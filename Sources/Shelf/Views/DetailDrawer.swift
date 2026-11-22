import AppKit
import QuartzCore
import SwiftUI

struct DetailDrawerLayout: ViewModifier {
    let workspaceWidth: CGFloat
    let initialPosterID: UUID?
    let onReplaceCover: (MediaItem) -> Void
    @State private var isDocked = false

    func body(content: Content) -> some View {
        let inset = isDocked ? min(workspaceWidth, DetailDrawer.width) : 0
        content
            .frame(width: workspaceWidth - inset, alignment: .leading)
            .clipped()
            .padding(.trailing, inset)
            .overlay(alignment: .trailing) {
                DetailDrawer(onReplaceCover: onReplaceCover, onDockChange: { isDocked = $0 },
                             initialPosterID: initialPosterID)
            }
    }
}

struct DetailDrawer: View {
    static let width: CGFloat = 321

    let onReplaceCover: (MediaItem) -> Void
    let onDockChange: (Bool) -> Void
    var initialPosterID: UUID?

    @Environment(LibraryStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let item = store.selectedItem
        DetailDrawerHost(
            item: item, initialPosterID: initialPosterID, store: store, reduceMotion: reduceMotion,
            onReplaceCover: onReplaceCover, onDockChange: onDockChange
        )
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .allowsHitTesting(item != nil)
        .accessibilityHidden(item == nil)
    }
}

private struct DetailDrawerHost: NSViewRepresentable {
    let item: MediaItem?
    let initialPosterID: UUID?
    let store: LibraryStore
    let reduceMotion: Bool
    let onReplaceCover: (MediaItem) -> Void
    let onDockChange: (Bool) -> Void

    func makeNSView(context: Context) -> DetailDrawerClipView {
        DetailDrawerClipView()
    }

    func updateNSView(_ view: DetailDrawerClipView, context: Context) {
        view.update(item: item, initialPosterID: initialPosterID, store: store, reduceMotion: reduceMotion,
                    onReplaceCover: onReplaceCover, onDockChange: onDockChange)
    }

    static func dismantleNSView(_ nsView: DetailDrawerClipView, coordinator: ()) {
        nsView.tearDown()
    }
}

/// Keep the panel at its final size and move that backing layer as a unit.
@MainActor
final class DetailDrawerClipView: NSView {
    private let slidingView = NSView()
    private let panel = NSHostingView(rootView: HostedDetailPanel())
    private var displayedItem: MediaItem?
    private var isShowing = false
    private var reduceMotion = false
    private var preparation: Task<Void, Never>?
    private var docking: Task<Void, Never>?
    private var isDocked = false
    private var onDockChange: ((Bool) -> Void)?
    private let animationKey = "drawerSlide"
    private let selectionAnimationKey = "drawerSelection"
    private var restingOffset = DetailDrawer.width

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        clipsToBounds = true
        slidingView.wantsLayer = true
        addSubview(slidingView)
        layer?.sublayerTransform = CATransform3DMakeTranslation(restingOffset, 0, 0)
        panel.sizingOptions = []
        slidingView.addSubview(panel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        preparation?.cancel()
        docking?.cancel()
    }

    func tearDown() {
        preparation?.cancel()
        preparation = nil
        docking?.cancel()
        docking = nil
        onDockChange = nil
        displayedItem = nil
        panel.rootView = HostedDetailPanel(content: nil)
    }

    override func layout() {
        super.layout()
        if slidingView.frame != bounds { slidingView.frame = bounds }
        if panel.frame != slidingView.bounds { panel.frame = slidingView.bounds }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isShowing else { return nil }
        if let layer, layer.animation(forKey: animationKey) != nil {
            let local = convert(point, from: superview)
            let offset = layer.presentation()?.sublayerTransform.m41 ?? DetailDrawer.width
            return bounds.contains(local) && local.x >= offset ? self : nil
        }
        return super.hitTest(point)
    }

    func update(item: MediaItem?, initialPosterID: UUID?, store: LibraryStore, reduceMotion: Bool,
                onReplaceCover: @escaping (MediaItem) -> Void, onDockChange: @escaping (Bool) -> Void) {
        let opening = item != nil
        self.onDockChange = onDockChange
        let motionChanged = self.reduceMotion != reduceMotion
        self.reduceMotion = reduceMotion
        if opening {
            preparation?.cancel()
            preparation = nil
        } else if displayedItem == nil, preparation == nil, let initialPosterID {
            preparation = Task { [weak self, weak store] in
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled, let self else { return }
                self.preparation = nil
                guard let window = self.window, window.isVisible, !window.inLiveResize,
                      let store, let first = store.item(withID: initialPosterID) else { return }
                if let event = NSApp.currentEvent, event.window === window, event.type == .scrollWheel,
                   ProcessInfo.processInfo.systemUptime - event.timestamp < 0.2 { return }
                self.show(first, store: store, isShowing: false, animateSelection: false, onReplaceCover: onReplaceCover)
                self.panel.layoutSubtreeIfNeeded()
            }
        }

        if let content = item ?? displayedItem,
           content != displayedItem || opening != isShowing {
            let animateSelection = !reduceMotion && opening && isShowing && displayedItem?.id != content.id
                && window != nil && layer?.animation(forKey: animationKey) == nil
            show(content, store: store, isShowing: opening, animateSelection: animateSelection,
                 onReplaceCover: onReplaceCover)
        }

        if opening != isShowing || motionChanged {
            isShowing = opening
            panel.layer?.removeAnimation(forKey: selectionAnimationKey)
            if !opening, let field = window?.firstResponder as? NSView, field.isDescendant(of: slidingView) {
                window?.makeFirstResponder(nil)
            }
            slide(open: opening, animated: !reduceMotion && window != nil)
        }
    }

    private func show(_ item: MediaItem, store: LibraryStore, isShowing: Bool, animateSelection: Bool,
                      onReplaceCover: @escaping (MediaItem) -> Void) {
        if animateSelection {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.18
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.layer?.add(fade, forKey: selectionAnimationKey)
        }
        panel.rootView = HostedDetailPanel(content: .init(item: item, store: store, isShowing: isShowing,
                                                         onReplaceCover: onReplaceCover))
        if animateSelection { panel.layoutSubtreeIfNeeded() }
        displayedItem = item
    }

    private func slide(open: Bool, animated: Bool) {
        guard let layer else { return }
        let x: CGFloat = open ? 0 : DetailDrawer.width
        let currentX = layer.animation(forKey: animationKey) == nil
            ? restingOffset : (layer.presentation()?.sublayerTransform.m41 ?? restingOffset)
        restingOffset = x
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: animationKey)
        layer.sublayerTransform = CATransform3DMakeTranslation(x, 0, 0)
        var dockDelay = 0.0
        if animated && abs(currentX - x) > 0.5 {
            let animation = CABasicAnimation(keyPath: "sublayerTransform")
            animation.fromValue = NSValue(caTransform3D: CATransform3DMakeTranslation(currentX, 0, 0))
            animation.toValue = NSValue(caTransform3D: layer.sublayerTransform)
            let distance = min(1, abs(currentX - x) / DetailDrawer.width)
            animation.duration = 0.12 + (open ? 0.22 : 0.18) * distance
            animation.timingFunction = open
                ? CAMediaTimingFunction(controlPoints: 0.34, 0.12, 0.29, 1)
                : CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(animation, forKey: animationKey)
            // Reflow while the drawer still covers most of the dock, in either direction.
            dockDelay = animation.duration * (open ? 0.59 : 0.24)
        }
        CATransaction.commit()
        scheduleDock(open, after: dockDelay)
    }

    private func scheduleDock(_ open: Bool, after delay: TimeInterval) {
        docking?.cancel()
        docking = nil
        guard isDocked != open else { return }
        docking = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard let self, !Task.isCancelled else { return }
            self.docking = nil
            self.isDocked = open
            self.onDockChange?(open)
        }
    }
}

private struct HostedDetailPanel: View {
    struct Content {
        let item: MediaItem
        let store: LibraryStore
        let isShowing: Bool
        let onReplaceCover: (MediaItem) -> Void
    }
    var content: Content?

    var body: some View {
        if let content {
            HStack(spacing: 0) {
                Divider()
                ItemDetailPanel(item: content.item, isShowing: content.isShowing,
                                onReplaceCover: { content.onReplaceCover(content.item) },
                                onClose: { content.store.selectedItemID = nil })
                    .environment(content.store)
            }
            .accessibilityHidden(!content.isShowing)
        }
    }
}
