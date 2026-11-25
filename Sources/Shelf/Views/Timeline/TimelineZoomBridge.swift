import AppKit
import Observation
import QuartzCore
import SwiftUI

/// Lightweight observable scroll viewport state so sticky swimlane headers, sticky year badges,
/// and wide-card sticky titles update smoothly without invalidating the entire timeline view tree.
@MainActor @Observable
final class TimelineScrollTracker {
    var offsetX: CGFloat = 0
    var viewportWidth: CGFloat = 0

    func update(offsetX: CGFloat, viewportWidth: CGFloat) {
        let clampedX = max(0, offsetX)
        let clampedW = max(0, viewportWidth)
        if abs(self.offsetX - clampedX) > 0.5 {
            self.offsetX = clampedX
        }
        if abs(self.viewportWidth - clampedW) > 0.5 {
            self.viewportWidth = clampedW
        }
    }
}

/// Request to smoothly scroll the horizontal timeline to a specific content X coordinate via AppKit.
struct TimelineScrollCommand: Equatable {
    enum Anchor: Equatable {
        case leading
        case center
        case trailing
    }

    let nonce: Int
    let targetX: CGFloat
    let anchor: Anchor
    let animated: Bool
}

/// Request to smoothly interpolate timeline zoom locked to the screen's native CADisplayLink (up to 120Hz ProMotion).
struct TimelinePresetZoomCommand: Equatable {
    let nonce: Int
    let fromZoom: Double
    let toZoom: Double
}

/// Bridges the enclosing horizontal `NSScrollView` for native 120Hz trackpad pinch-to-zoom,
/// zero-lag focal-point scroll anchoring (keeping the date under the cursor or viewport center fixed in the same frame),
/// display-synced preset zoom animation, native smooth horizontal scrolling, and lightweight viewport reporting.
struct TimelineZoomBridge: NSViewRepresentable {
    let effectiveZoom: Double
    let pointsPerDay: CGFloat
    let totalWidth: CGFloat
    let leadingPadding: CGFloat
    let animatingPreset: Bool
    var scrollCommand: TimelineScrollCommand? = nil
    var presetCommand: TimelinePresetZoomCommand? = nil
    let onScroll: () -> Void
    let onPinchBegin: () -> Void
    let onPinchChanged: (Double) -> Void
    let onPinchEnded: (Double) -> Void
    var onPresetFrame: ((Double) -> Void)? = nil
    var onPresetFinished: (() -> Void)? = nil
    var onViewportChanged: ((CGFloat, CGFloat) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> BridgeNSView {
        let view = BridgeNSView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: BridgeNSView, context: Context) {
        let coord = context.coordinator
        coord.hostView = nsView
        coord.onScroll = onScroll
        coord.onPinchBegin = onPinchBegin
        coord.onPinchChanged = onPinchChanged
        coord.onPinchEnded = onPinchEnded
        coord.onPresetFrame = onPresetFrame
        coord.onPresetFinished = onPresetFinished
        coord.onViewportChanged = onViewportChanged
        coord.leadingPadding = leadingPadding
        coord.totalWidth = totalWidth
        coord.syncZoomState(effectiveZoom: effectiveZoom, pointsPerDay: pointsPerDay, animatingPreset: animatingPreset)
        coord.handlePresetCommand(presetCommand)
        coord.handleScrollCommand(scrollCommand)
    }

    static func dismantleNSView(_ nsView: BridgeNSView, coordinator: Coordinator) {
        coordinator.tearDown()
    }

    final class BridgeNSView: NSView {
        weak var coordinator: Coordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                coordinator?.attach(hostView: self)
            } else {
                coordinator?.detachMonitor()
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var hostView: BridgeNSView?
        weak var scrollView: NSScrollView?
        private weak var observedDocumentView: NSView?

        var onScroll: (() -> Void)?
        var onPinchBegin: (() -> Void)?
        var onPinchChanged: ((Double) -> Void)?
        var onPinchEnded: ((Double) -> Void)?
        var onPresetFrame: ((Double) -> Void)?
        var onPresetFinished: (() -> Void)?
        var onViewportChanged: ((CGFloat, CGFloat) -> Void)?
        var leadingPadding: CGFloat = TimelineLayoutModel.leadingCanvasPadding
        var totalWidth: CGFloat = 0

        private var currentZoom: Double = TimelineZoomConfig.defaultZoom
        private var lastAppliedPPD: CGFloat?
        private var isPinching = false
        private var lockedFocalDay: CGFloat?
        private var lockedAnchorX: CGFloat?
        private var presetFocalDay: CGFloat?
        private var pendingScrollToken: UInt64 = 0
        private var pendingTargetX: CGFloat?
        private var lastScrollCommandNonce: Int = 0
        private var lastPresetCommandNonce: Int = 0

        private var displayLink: CADisplayLink?
        private var presetStartTime: CFTimeInterval = 0
        private var presetFromZoom: Double = 0
        private var presetToZoom: Double = 0
        private let presetDuration: CFTimeInterval = 0.26

        private nonisolated(unsafe) var inputMonitor: Any?
        private nonisolated(unsafe) var boundsObserver: NSObjectProtocol?
        private nonisolated(unsafe) var frameObserver: NSObjectProtocol?
        private nonisolated(unsafe) var documentFrameObserver: NSObjectProtocol?

        deinit {
            if let monitor = inputMonitor {
                NSEvent.removeMonitor(monitor)
                inputMonitor = nil
            }
            if let observer = boundsObserver {
                NotificationCenter.default.removeObserver(observer)
                boundsObserver = nil
            }
            if let observer = frameObserver {
                NotificationCenter.default.removeObserver(observer)
                frameObserver = nil
            }
            if let observer = documentFrameObserver {
                NotificationCenter.default.removeObserver(observer)
                documentFrameObserver = nil
            }
        }

        func attach(hostView: BridgeNSView) {
            self.hostView = hostView
            resolveScrollView()
            installMonitorIfNeeded()
            reportCurrentViewport()
        }

        func detachMonitor() {
            stopDisplayLink()
            pendingScrollToken &+= 1
            pendingTargetX = nil
            presetFocalDay = nil
            if let monitor = inputMonitor {
                NSEvent.removeMonitor(monitor)
                inputMonitor = nil
            }
            removeViewportObservers()
            isPinching = false
            lockedFocalDay = nil
            lockedAnchorX = nil
        }

        func tearDown() {
            detachMonitor()
            scrollView = nil
            observedDocumentView = nil
            hostView = nil
        }

        private func removeViewportObservers() {
            if let observer = boundsObserver {
                NotificationCenter.default.removeObserver(observer)
                boundsObserver = nil
            }
            if let observer = frameObserver {
                NotificationCenter.default.removeObserver(observer)
                frameObserver = nil
            }
            if let observer = documentFrameObserver {
                NotificationCenter.default.removeObserver(observer)
                documentFrameObserver = nil
            }
            observedDocumentView = nil
        }

        private func resolveScrollView() {
            guard let sv = hostView?.enclosingScrollView else { return }
            if scrollView !== sv {
                removeViewportObservers()
                scrollView = sv
                let clipView = sv.contentView
                clipView.postsBoundsChangedNotifications = true
                clipView.postsFrameChangedNotifications = true

                boundsObserver = NotificationCenter.default.addObserver(
                    forName: NSView.boundsDidChangeNotification,
                    object: clipView,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.reportCurrentViewport()
                    }
                }
                frameObserver = NotificationCenter.default.addObserver(
                    forName: NSView.frameDidChangeNotification,
                    object: clipView,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.reportCurrentViewport()
                    }
                }
                attachDocumentObserverIfNeeded(in: sv)
                reportCurrentViewport()
            } else {
                attachDocumentObserverIfNeeded(in: sv)
            }
        }

        private func attachDocumentObserverIfNeeded(in sv: NSScrollView) {
            guard let doc = sv.documentView, observedDocumentView !== doc else { return }
            if let observer = documentFrameObserver {
                NotificationCenter.default.removeObserver(observer)
                documentFrameObserver = nil
            }
            observedDocumentView = doc
            doc.postsFrameChangedNotifications = true
            documentFrameObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: doc,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.applyPendingScrollCorrectionIfReady()
                }
            }
        }

        private func reportCurrentViewport() {
            guard let sv = scrollView else { return }
            let bounds = sv.contentView.bounds
            onViewportChanged?(bounds.origin.x, bounds.width)
        }

        private func installMonitorIfNeeded() {
            guard inputMonitor == nil else { return }
            inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.magnify, .scrollWheel]) { [weak self] event in
                guard let self else { return event }
                if event.type == .scrollWheel {
                    if let sv = self.scrollView, sv.window === event.window,
                       sv.bounds.contains(sv.convert(event.locationInWindow, from: nil)) {
                        self.stopDisplayLink()
                        self.onScroll?()
                    }
                    return event
                }
                return self.handleMagnify(event)
            }
        }

        // MARK: - VSync DisplayLink Preset Zoom

        func handlePresetCommand(_ command: TimelinePresetZoomCommand?) {
            guard let command else {
                if displayLink != nil { stopDisplayLink() }
                return
            }
            guard command.nonce != lastPresetCommandNonce else { return }
            lastPresetCommandNonce = command.nonce
            startDisplayLinkPresetZoom(from: command.fromZoom, to: command.toZoom)
        }

        private func startDisplayLinkPresetZoom(from startZoom: Double, to targetZoom: Double) {
            stopDisplayLink()
            guard let hostView, hostView.window != nil else {
                onPresetFinished?()
                return
            }
            presetFromZoom = startZoom
            presetToZoom = targetZoom
            presetStartTime = CACurrentMediaTime()

            let link = hostView.displayLink(target: self, selector: #selector(handleDisplayLinkTick(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        @objc private func handleDisplayLinkTick(_ link: CADisplayLink) {
            let elapsed = CACurrentMediaTime() - presetStartTime
            let raw = min(1.0, max(0.0, elapsed / presetDuration))
            if raw >= 1.0 {
                stopDisplayLink()
                onPresetFinished?()
                return
            }
            // Smooth quintic ease-out-in curve for buttery 120Hz ProMotion zoom deceleration.
            let eased = raw < 0.5
                ? 4 * raw * raw * raw
                : 1 - pow(-2 * raw + 2, 3) / 2
            let interpolated = presetFromZoom + (presetToZoom - presetFromZoom) * eased
            onPresetFrame?(interpolated)
        }

        private func stopDisplayLink() {
            displayLink?.invalidate()
            displayLink = nil
        }

        // MARK: - Native Smooth Horizontal Scroll

        func handleScrollCommand(_ command: TimelineScrollCommand?) {
            guard let command, command.nonce != lastScrollCommandNonce else { return }
            lastScrollCommandNonce = command.nonce
            if scrollView == nil { resolveScrollView() }
            guard let sv = scrollView else { return }

            sv.layoutSubtreeIfNeeded()
            let clipView = sv.contentView
            let viewportW = clipView.bounds.width
            let actualDocWidth = sv.documentView?.frame.width ?? 0
            let docWidth = totalWidth > 0 ? max(actualDocWidth, totalWidth) : actualDocWidth
            let maxScrollX = max(0, docWidth - viewportW)

            let desiredX: CGFloat
            switch command.anchor {
            case .leading:
                desiredX = command.targetX - 28
            case .center:
                desiredX = command.targetX - viewportW * 0.5
            case .trailing:
                desiredX = command.targetX - viewportW + 72
            }
            let clampedX = min(max(desiredX, 0), maxScrollX)
            let targetOrigin = NSPoint(x: clampedX, y: clipView.bounds.origin.y)

            if command.animated && abs(clipView.bounds.origin.x - clampedX) > 1 {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.38
                    ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
                    ctx.allowsImplicitAnimation = true
                    clipView.animator().setBoundsOrigin(targetOrigin)
                } completionHandler: { [weak self, weak sv] in
                    MainActor.assumeIsolated {
                        if let sv { sv.reflectScrolledClipView(sv.contentView) }
                        self?.reportCurrentViewport()
                    }
                }
            } else {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                clipView.setBoundsOrigin(targetOrigin)
                sv.reflectScrolledClipView(clipView)
                CATransaction.commit()
                reportCurrentViewport()
            }
        }

        // MARK: - Trackpad Pinch Handling

        private func handleMagnify(_ event: NSEvent) -> NSEvent? {
            if scrollView == nil { resolveScrollView() }
            guard let hostView,
                  let window = hostView.window,
                  event.window === window,
                  let sv = scrollView
            else {
                return event
            }

            let clipView = sv.contentView
            let localInScroll = sv.convert(event.locationInWindow, from: nil)
            let isInside = sv.bounds.contains(localInScroll)

            if !isPinching && !isInside {
                return event
            }

            let clipWidth = max(1, clipView.bounds.width)
            let anchorX = min(max(localInScroll.x, 0), clipWidth)

            switch event.phase {
            case .began:
                stopDisplayLink()
                isPinching = true
                let ppd = lastAppliedPPD ?? TimelineZoomConfig.pointsPerDay(for: currentZoom)
                lockedAnchorX = anchorX
                lockedFocalDay = (clipView.bounds.origin.x + anchorX - leadingPadding) / max(ppd, 0.5)
                onPinchBegin?()
                applyMagnificationDelta(event.magnification, anchorX: anchorX)

            case .changed:
                if !isPinching {
                    stopDisplayLink()
                    isPinching = true
                    let ppd = lastAppliedPPD ?? TimelineZoomConfig.pointsPerDay(for: currentZoom)
                    lockedAnchorX = anchorX
                    lockedFocalDay = (clipView.bounds.origin.x + anchorX - leadingPadding) / max(ppd, 0.5)
                    onPinchBegin?()
                }
                applyMagnificationDelta(event.magnification, anchorX: anchorX)

            case .ended, .cancelled:
                if isPinching {
                    applyMagnificationDelta(event.magnification, anchorX: anchorX)
                    let finalZoom = currentZoom
                    isPinching = false
                    onPinchEnded?(finalZoom)
                }

            default:
                if isInside {
                    stopDisplayLink()
                    let ppd = lastAppliedPPD ?? TimelineZoomConfig.pointsPerDay(for: currentZoom)
                    lockedAnchorX = anchorX
                    lockedFocalDay = (clipView.bounds.origin.x + anchorX - leadingPadding) / max(ppd, 0.5)
                    onPinchBegin?()
                    applyMagnificationDelta(event.magnification, anchorX: anchorX)
                    onPinchEnded?(currentZoom)
                }
            }

            return nil
        }

        private func applyMagnificationDelta(_ delta: CGFloat, anchorX: CGFloat) {
            let step = Double(delta) * 0.65
            let nextZoom = min(max(currentZoom + step, TimelineZoomConfig.minZoom), TimelineZoomConfig.maxZoom)
            lockedAnchorX = anchorX
            guard abs(nextZoom - currentZoom) > 0.0001 else { return }
            currentZoom = nextZoom
            onPinchChanged?(nextZoom)
        }

        func syncZoomState(effectiveZoom: Double, pointsPerDay: CGFloat, animatingPreset: Bool) {
            defer {
                if !animatingPreset { presetFocalDay = nil }
                if !isPinching {
                    lockedFocalDay = nil
                    lockedAnchorX = nil
                }
            }
            if scrollView == nil { resolveScrollView() }

            if !isPinching {
                currentZoom = effectiveZoom
            }

            guard let previousPPD = lastAppliedPPD else {
                lastAppliedPPD = pointsPerDay
                return
            }

            guard let sv = scrollView else {
                lastAppliedPPD = pointsPerDay
                return
            }
            let clipView = sv.contentView
            let clipWidth = max(1, clipView.bounds.width)
            if animatingPreset, presetFocalDay == nil {
                presetFocalDay = (clipView.bounds.origin.x + clipWidth * 0.5 - leadingPadding) / previousPPD
            }

            guard abs(pointsPerDay - previousPPD) > 0.00001 else { return }
            lastAppliedPPD = pointsPerDay

            let focalDay: CGFloat
            let anchorX: CGFloat
            if let lockedDay = lockedFocalDay, let lockedX = lockedAnchorX {
                focalDay = lockedDay
                anchorX = lockedX
            } else {
                anchorX = clipWidth * 0.5
                focalDay = presetFocalDay ?? ((clipView.bounds.origin.x + anchorX - leadingPadding) / max(previousPPD, 0.5))
            }

            let desiredX = leadingPadding + focalDay * pointsPerDay - anchorX
            scheduleScrollCorrection(targetX: desiredX, in: sv)
        }

        private func scheduleScrollCorrection(targetX: CGFloat, in scrollView: NSScrollView) {
            pendingScrollToken &+= 1
            pendingTargetX = targetX
            let token = pendingScrollToken

            DispatchQueue.main.async { [weak self, weak scrollView] in
                guard let self, let scrollView, self.pendingScrollToken == token,
                      let remainingTarget = self.pendingTargetX else { return }
                self.pendingTargetX = nil
                self.applyScrollOrigin(remainingTarget, in: scrollView, layoutIfNeeded: true)
            }
        }

        private func applyPendingScrollCorrectionIfReady() {
            guard let sv = scrollView, let targetX = pendingTargetX else { return }
            // Apply synchronously inside the same layout pass when SwiftUI resizes documentView -> 0-frame zoom jitter.
            pendingTargetX = nil
            applyScrollOrigin(targetX, in: sv, layoutIfNeeded: false)
        }

        private func applyScrollOrigin(_ targetX: CGFloat, in scrollView: NSScrollView, layoutIfNeeded: Bool) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if layoutIfNeeded { scrollView.layoutSubtreeIfNeeded() }
            let clipView = scrollView.contentView
            let actualDocWidth = scrollView.documentView?.frame.width ?? 0
            let docWidth = totalWidth > 0 ? max(actualDocWidth, totalWidth) : actualDocWidth
            let maxScrollX = max(0, docWidth - clipView.bounds.width)
            let clampedX = min(max(targetX, 0), maxScrollX)
            let currentY = clipView.bounds.origin.y
            if abs(clipView.bounds.origin.x - clampedX) > 0.25 {
                clipView.setBoundsOrigin(NSPoint(x: clampedX, y: currentY))
                scrollView.reflectScrolledClipView(clipView)
            }
            CATransaction.commit()
            reportCurrentViewport()
        }
    }
}
