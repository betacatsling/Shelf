import AppKit
import SwiftUI

/// Bridges the enclosing horizontal `NSScrollView` for native 120Hz trackpad pinch-to-zoom
/// and focal-point scroll anchoring (keeping the date under the cursor or viewport center fixed while zooming).
struct TimelineZoomBridge: NSViewRepresentable {
    let effectiveZoom: Double
    let pointsPerDay: CGFloat
    let totalWidth: CGFloat
    let leadingPadding: CGFloat
    let onPinchBegin: () -> Void
    let onPinchChanged: (Double) -> Void
    let onPinchEnded: (Double) -> Void

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
        coord.onPinchBegin = onPinchBegin
        coord.onPinchChanged = onPinchChanged
        coord.onPinchEnded = onPinchEnded
        coord.leadingPadding = leadingPadding
        coord.totalWidth = totalWidth
        coord.syncZoomState(effectiveZoom: effectiveZoom, pointsPerDay: pointsPerDay)
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
    final class Coordinator {
        weak var hostView: BridgeNSView?
        weak var scrollView: NSScrollView?

        var onPinchBegin: (() -> Void)?
        var onPinchChanged: ((Double) -> Void)?
        var onPinchEnded: ((Double) -> Void)?
        var leadingPadding: CGFloat = TimelineLayoutModel.leadingCanvasPadding
        var totalWidth: CGFloat = 0

        private var currentZoom: Double = TimelineZoomConfig.defaultZoom
        private var lastAppliedPPD: CGFloat?
        private var isPinching = false
        private var lockedFocalDay: CGFloat?
        private var lockedAnchorX: CGFloat?
        private var pendingScrollToken: UInt64 = 0
        private nonisolated(unsafe) var magnifyMonitor: Any?

        deinit {
            if let monitor = magnifyMonitor {
                NSEvent.removeMonitor(monitor)
                magnifyMonitor = nil
            }
        }

        func attach(hostView: BridgeNSView) {
            self.hostView = hostView
            resolveScrollView()
            installMonitorIfNeeded()
        }

        func detachMonitor() {
            if let monitor = magnifyMonitor {
                NSEvent.removeMonitor(monitor)
                magnifyMonitor = nil
            }
            isPinching = false
            lockedFocalDay = nil
            lockedAnchorX = nil
        }

        func tearDown() {
            detachMonitor()
            scrollView = nil
            hostView = nil
        }

        private func resolveScrollView() {
            if let sv = hostView?.enclosingScrollView {
                scrollView = sv
            }
        }

        private func installMonitorIfNeeded() {
            guard magnifyMonitor == nil else { return }
            magnifyMonitor = NSEvent.addLocalMonitorForEvents(matching: .magnify) { [weak self] event in
                guard let self else { return event }
                return self.handleMagnify(event)
            }
        }

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
                isPinching = true
                let ppd = lastAppliedPPD ?? TimelineZoomConfig.pointsPerDay(for: currentZoom)
                lockedAnchorX = anchorX
                lockedFocalDay = (clipView.bounds.origin.x + anchorX - leadingPadding) / max(ppd, 0.5)
                onPinchBegin?()
                applyMagnificationDelta(event.magnification, anchorX: anchorX)

            case .changed:
                if !isPinching {
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
                    // Keep anchor through the final commit frame, then clear
                    DispatchQueue.main.async { [weak self] in
                        guard let self, !self.isPinching else { return }
                        self.lockedFocalDay = nil
                        self.lockedAnchorX = nil
                    }
                }

            default:
                // Discrete magnify event without explicit phase (e.g. smart zoom or synthetic gesture)
                if isInside {
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
            // Trackpad pinch magnification delta is roughly [-0.08, +0.08] per frame.
            // Scaling by 0.65 gives a responsive, natural 1:1 feel across the exponential zoom curve.
            let step = Double(delta) * 0.65
            let nextZoom = min(max(currentZoom + step, TimelineZoomConfig.minZoom), TimelineZoomConfig.maxZoom)
            lockedAnchorX = anchorX
            guard abs(nextZoom - currentZoom) > 0.0001 else { return }
            currentZoom = nextZoom
            onPinchChanged?(nextZoom)
        }

        func syncZoomState(effectiveZoom: Double, pointsPerDay: CGFloat) {
            if scrollView == nil { resolveScrollView() }

            if !isPinching {
                currentZoom = effectiveZoom
            }

            guard let previousPPD = lastAppliedPPD else {
                lastAppliedPPD = pointsPerDay
                return
            }

            guard abs(pointsPerDay - previousPPD) > 0.001 else { return }
            lastAppliedPPD = pointsPerDay

            guard let sv = scrollView else { return }
            let clipView = sv.contentView
            let clipWidth = max(1, clipView.bounds.width)

            let focalDay: CGFloat
            let anchorX: CGFloat
            if let lockedDay = lockedFocalDay, let lockedX = lockedAnchorX {
                focalDay = lockedDay
                anchorX = lockedX
            } else {
                // Non-pinch zoom (presets, slider, ⌘+/⌘-): anchor around viewport center
                anchorX = clipWidth * 0.5
                focalDay = (clipView.bounds.origin.x + anchorX - leadingPadding) / max(previousPPD, 0.5)
            }

            let desiredX = leadingPadding + focalDay * pointsPerDay - anchorX
            scheduleScrollCorrection(targetX: desiredX, in: sv)
        }

        private func scheduleScrollCorrection(targetX: CGFloat, in scrollView: NSScrollView) {
            pendingScrollToken &+= 1
            let token = pendingScrollToken
            let expectedTotalWidth = totalWidth

            DispatchQueue.main.async { [weak self, weak scrollView] in
                guard let self, let scrollView, self.pendingScrollToken == token else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                scrollView.layoutSubtreeIfNeeded()
                let clipView = scrollView.contentView
                let actualDocWidth = scrollView.documentView?.frame.width ?? 0
                let docWidth = expectedTotalWidth > 0 ? max(actualDocWidth, expectedTotalWidth) : actualDocWidth
                let maxScrollX = max(0, docWidth - clipView.bounds.width)
                let clampedX = min(max(targetX, 0), maxScrollX)
                let currentY = clipView.bounds.origin.y
                if abs(clipView.bounds.origin.x - clampedX) > 0.25 {
                    clipView.setBoundsOrigin(NSPoint(x: clampedX, y: currentY))
                    scrollView.reflectScrolledClipView(clipView)
                }
                CATransaction.commit()
            }
        }
    }
}
