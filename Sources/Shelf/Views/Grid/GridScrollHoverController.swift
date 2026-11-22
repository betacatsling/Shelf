import AppKit

/// Manages scroll-view NotificationCenter observers and live-scroll / momentum hover suspension.
@MainActor
final class GridScrollHoverController {
    private(set) var isLiveScrolling = false
    private var isTrackingScroll = false
    private var hoverResumeDeadline = ContinuousClock.Instant.now
    private var hoverResumeTask: Task<Void, Never>?
    private nonisolated(unsafe) var observers: [NSObjectProtocol] = []

    var onStartLiveScroll: (() -> Void)?
    var onSuspendHover: (() -> Void)?
    var onRestoreHover: (() -> Void)?
    var onClipFrameChanged: (() -> Void)?
    var onClipBoundsChanged: (() -> Void)?

    deinit {
        for obs in observers {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    func install(for scrollView: NSScrollView) {
        removeObservers()
        let nc = NotificationCenter.default
        scrollView.contentView.postsBoundsChangedNotifications = true

        let startObs = nc.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isTrackingScroll = true
                self.hoverResumeTask?.cancel()
                self.hoverResumeTask = nil
                self.suspendHoverForScrolling()
                self.onStartLiveScroll?()
            }
        }

        let endObs = nc.addObserver(
            forName: NSScrollView.didEndLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isTrackingScroll = false
                self.scheduleHoverResume()
            }
        }

        let frameObs = nc.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.onClipFrameChanged?()
            }
        }

        let scrollObs = nc.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.onClipBoundsChanged?()
            }
        }

        let liveObs = nc.addObserver(
            forName: NSScrollView.didLiveScrollNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.suspendHoverForScrolling()
                self?.scheduleHoverResume()
            }
        }

        observers = [startObs, endObs, frameObs, scrollObs, liveObs]
    }

    func scheduleHoverResume() {
        // Tracking can end before momentum or elastic bounce does. Wheel mice
        // may also scroll without sending a tracking start or end notification.
        guard isLiveScrolling, !isTrackingScroll else { return }
        hoverResumeDeadline = .now + .milliseconds(120)
        guard hoverResumeTask == nil else { return }
        hoverResumeTask = Task { [weak self] in
            while let deadline = self?.hoverResumeDeadline {
                try? await ContinuousClock().sleep(until: deadline)
                guard !Task.isCancelled, let self else { return }
                guard self.hoverResumeDeadline == deadline else { continue }
                self.hoverResumeTask = nil
                self.isLiveScrolling = false
                self.onRestoreHover?()
                return
            }
        }
    }

    func detach() {
        hoverResumeTask?.cancel()
        hoverResumeTask = nil
        isLiveScrolling = false
        isTrackingScroll = false
        removeObservers()
    }

    private func suspendHoverForScrolling() {
        guard !isLiveScrolling else { return }
        // Let the hovered card return to its resting position without snapping.
        onSuspendHover?()
        isLiveScrolling = true
    }

    private func removeObservers() {
        for obs in observers {
            NotificationCenter.default.removeObserver(obs)
        }
        observers.removeAll()
    }
}
