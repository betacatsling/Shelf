import AppKit
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

extension TrackingStatus {
    var nsTintColor: NSColor {
        switch self {
        case .active: return NSColor(srgbRed: 0.20, green: 0.78, blue: 0.45, alpha: 1.0)
        case .completed: return NSColor(srgbRed: 0.34, green: 0.56, blue: 0.98, alpha: 1.0)
        case .unfinished: return NSColor(srgbRed: 0.92, green: 0.45, blue: 0.36, alpha: 1.0)
        case .backlog: return NSColor(srgbRed: 0.95, green: 0.68, blue: 0.22, alpha: 1.0)
        }
    }
}

// MARK: - SwiftUI Bridge

struct NativePosterGrid: NSViewRepresentable {
    let sections: [ShelfSectionModel]
    let collapsedShelves: Set<TrackingStatus>
    let selectedItemID: UUID?
    let showStatusBadges: Bool
    let posterScale: Double
    var posterWidthBasis: CGFloat? = nil
    let language: AppLanguage
    let scrollResetToken: Int

    let onSelectItem: (UUID) -> Void
    let onEnsureSelectItem: (UUID) -> Void
    let onDeselectAll: () -> Void
    let onDoubleClickEdit: (UUID) -> Void
    var onRequestEditTags: (UUID) -> Void = { _ in }
    let onRequestReplaceCover: (UUID) -> Void
    let onToggleSectionCollapse: (TrackingStatus) -> Void
    let onQuickAddInSection: (TrackingStatus) -> Void
    let onChangeStatus: (UUID, TrackingStatus) -> Void
    let onChangeRating: (UUID, Int) -> Void
    let onUpdateCoverFileName: (UUID, String?) -> Void
    let onImportCover: (UUID, CoverSource) -> Void
    let onDeleteItem: (UUID) -> Void
    let onShowToast: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        coordinator.reduceMotion = context.environment.accessibilityReduceMotion

        let initialRect = NSRect(x: 0, y: 0, width: 900, height: 640)
        let scrollView = NSScrollView(frame: initialRect)
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.usesPredominantAxisScrolling = true
        scrollView.borderType = .noBorder
        scrollView.contentView.postsFrameChangedNotifications = true

        let grid = PosterGridView(frame: initialRect)
        grid.coordinator = coordinator
        scrollView.documentView = grid

        coordinator.scrollView = scrollView
        coordinator.gridView = grid
        coordinator.installScrollObservers(for: scrollView)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.reduceMotion = context.environment.accessibilityReduceMotion
        context.coordinator.update(self)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.detach()
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject {
        private struct ViewportAnchor {
            let id: UUID
            let offset: CGFloat
        }

        var parent: NativePosterGrid
        weak var scrollView: NSScrollView?
        weak var gridView: PosterGridView?
        private var cards: [IndexPath: PosterCardInteractiveView] = [:]
        private var recycledCards: [PosterCardInteractiveView] = []
        private var headers: [Int: ShelfSectionHeaderView] = [:]
        private var recycledHeaders: [ShelfSectionHeaderView] = []
        private var mountedArea: CGRect?
        private var viewportSize: CGSize = .zero
        private var boundsObservationSuspended = false

        let layout = PosterGridLayout()
        private var sections: [ShelfSectionModel] = []
        private var selectedID: UUID?
        private var indexPaths: [UUID: IndexPath] = [:]
        private let prefetchOwner = UUID()
        private var prefetchPlan: [CoverManager.Request] = []
        private var prefetchAnchor: NSRect?
        private var movingUp = false
        private var hasLoadedInitialData = false
        private(set) var isLiveScrolling: Bool = false
        var reduceMotion = false {
            didSet {
                if reduceMotion && !oldValue {
                    for card in cards.values { card.cancelReflowAnimation() }
                }
            }
        }
        private var legacyScrollEnd: Task<Void, Never>?
        weak var activeHoveredView: PosterCardInteractiveView?

        private nonisolated(unsafe) var observers: [NSObjectProtocol] = []

        init(parent: NativePosterGrid) {
            self.parent = parent
        }

        deinit {
            for obs in observers {
                NotificationCenter.default.removeObserver(obs)
            }
        }

        func installScrollObservers(for scrollView: NSScrollView) {
            let nc = NotificationCenter.default
            scrollView.contentView.postsBoundsChangedNotifications = true
            let startObs = nc.addObserver(
                forName: NSScrollView.willStartLiveScrollNotification,
                object: scrollView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.legacyScrollEnd?.cancel()
                    self.legacyScrollEnd = nil
                    self.suspendHoverForScrolling()
                    self.updatePrefetchPlan()
                }
            }

            let endObs = nc.addObserver(
                forName: NSScrollView.didEndLiveScrollNotification,
                object: scrollView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.restoreHoverAfterScrolling()
                }
            }

            let frameObs = nc.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.clipFrameChanged()
                }
            }
            let scrollObs = nc.addObserver(
                forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.clipBoundsChanged() }
            }
            let legacyObs = nc.addObserver(
                forName: NSScrollView.didLiveScrollNotification, object: scrollView, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.extendHoverSuppressionForWheel() }
            }

            observers = [startObs, endObs, frameObs, scrollObs, legacyObs]
        }

        private func suspendHoverForScrolling() {
            isLiveScrolling = true
            clearHoveredCell(animated: false)
            for card in cards.values { card.cancelReflowAnimation() }
        }

        private func restoreHoverAfterScrolling() {
            isLiveScrolling = false
            if gridView?.window?.isKeyWindow == true {
                refreshHoverAtCurrentMouseLocation()
            }
        }

        private func extendHoverSuppressionForWheel() {
            // Trackpad and scrollbar gestures already send a start/end pair.
            guard !isLiveScrolling || legacyScrollEnd != nil else { return }
            if !isLiveScrolling { suspendHoverForScrolling() }
            legacyScrollEnd?.cancel()
            legacyScrollEnd = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled, let self else { return }
                self.legacyScrollEnd = nil
                self.restoreHoverAfterScrolling()
            }
        }

        func clearHoveredCell(animated: Bool) {
            activeHoveredView?.setHovered(false, animated: animated)
            activeHoveredView = nil
        }

        func refreshHoverAtCurrentMouseLocation(_ location: NSPoint? = nil) {
            guard let gridView, let window = gridView.window else { return }
            let winPt = location ?? window.mouseLocationOutsideOfEventStream
            let point = gridView.convert(winPt, from: nil)
            let target: PosterCardInteractiveView?
            if gridView.visibleRect.contains(point), let path = layout.itemPath(at: point),
               let card = cards[path], card.posterHitBounds.contains(card.convert(winPt, from: nil)) {
                target = card
            } else {
                target = nil
            }
            guard activeHoveredView !== target else { return }
            clearHoveredCell(animated: true)
            activeHoveredView = target
            target?.setHovered(true, animated: true)
        }

        private func updateSelectionAppearance(from oldID: UUID?, to newID: UUID?) {
            for case let id? in [oldID, newID] {
                if let path = indexPaths[id] {
                    cards[path]?.setSelected(id == newID)
                }
            }
        }

        func update(_ newParent: NativePosterGrid) {
            let oldParent = parent
            parent = newParent
            guard let scrollView else { return }
            let priorSelection = selectedID
            selectedID = parent.selectedItemID
            let clip = scrollView.contentView
            let savedY = clip.bounds.minY
            let resetScroll = oldParent.scrollResetToken != parent.scrollResetToken
            let scaleChanged = oldParent.posterScale != parent.posterScale
                || oldParent.posterWidthBasis != parent.posterWidthBasis
            let resized = viewportSize != clip.bounds.size
            let anchor = !resetScroll && (scaleChanged || resized) ? viewportAnchor(in: clip.bounds) : nil

            let initial = !hasLoadedInitialData
            let contentChanged = initial || oldParent.sections != parent.sections
                || oldParent.collapsedShelves != parent.collapsedShelves
            let oldSections = sections
            if contentChanged {
                sections = parent.sections.map { section in
                    var section = section
                    if let status = section.status {
                        section.isCollapsed = parent.collapsedShelves.contains(status)
                    }
                    return section
                }
            }

            let structureChanged = initial || (contentChanged && !hasSamePositions(as: oldSections))
            let appearanceChanged = contentChanged || oldParent.language != parent.language
                || oldParent.showStatusBadges != parent.showStatusBadges
            let previousFrames = !structureChanged && !scaleChanged && !resetScroll
                ? cardFramesBeforeDrawerResize(to: clip.bounds) : nil
            let opensDrawer = clip.bounds.width < viewportSize.width
            if structureChanged {
                hasLoadedInitialData = true
                clearHoveredCell(animated: false)
                for card in cards.values { card.cancelReflowAnimation() }
                stopPrefetching()
                rebuildIndexPaths()
            }

            if structureChanged || scaleChanged || resized || resetScroll {
                boundsObservationSuspended = true
                updateGridSize(for: clip.bounds.size)
                setScrollPosition(resetScroll ? 0 : restoredY(for: anchor, fallback: savedY), in: scrollView)
                boundsObservationSuspended = false
            }

            if appearanceChanged || scaleChanged || resized || resetScroll {
                updateMountedViews(force: true, reconfigure: appearanceChanged)
                animateReflow(from: previousFrames, in: clip.bounds, opensDrawer: opensDrawer)
                updatePrefetchPlan()
            }
            if priorSelection != selectedID {
                updateSelectionAppearance(from: priorSelection, to: selectedID)
            }
        }

        private func updateGridSize(for viewport: CGSize) {
            guard let gridView else { return }
            viewportSize = viewport
            layout.update(sections: sections, scale: parent.posterScale, width: viewport.width,
                          posterWidthBasis: parent.posterWidthBasis)
            let size = CGSize(width: viewport.width, height: max(layout.contentHeight, viewport.height))
            if gridView.frame.size != size { gridView.setFrameSize(size) }
        }

        private func clipFrameChanged() {
            guard !boundsObservationSuspended, let scrollView else { return }
            let viewport = scrollView.contentView.bounds
            guard viewport.size != viewportSize else { return }
            let anchor = viewport.width != viewportSize.width ? viewportAnchor(in: viewport) : nil
            let previousFrames = cardFramesBeforeDrawerResize(to: viewport)
            let opensDrawer = viewport.width < viewportSize.width
            boundsObservationSuspended = true
            updateGridSize(for: viewport.size)
            setScrollPosition(restoredY(for: anchor, fallback: viewport.minY), in: scrollView)
            boundsObservationSuspended = false
            updateMountedViews(force: true, reconfigure: false)
            animateReflow(from: previousFrames, in: scrollView.contentView.bounds, opensDrawer: opensDrawer)
            updatePrefetchPlan()
        }

        private func cardFramesBeforeDrawerResize(to viewport: CGRect) -> [IndexPath: CGRect]? {
            guard let fullWidth = parent.posterWidthBasis, !reduceMotion, !isLiveScrolling,
                  scrollView?.window?.inLiveResize == false, viewport.height == viewportSize.height,
                  abs(max(viewport.width, viewportSize.width) - fullWidth) < 1,
                  abs(abs(viewport.width - viewportSize.width) - DetailDrawer.width) < 1 else { return nil }

            let previous = CGRect(origin: viewport.origin, size: viewportSize)
            return cards.reduce(into: [:]) { frames, entry in
                let frame = entry.value.frame
                if previous.intersects(frame) {
                    frames[entry.key] = frame.offsetBy(dx: -previous.minX, dy: -previous.minY)
                }
            }
        }

        private func animateReflow(from previousFrames: [IndexPath: CGRect]?, in viewport: CGRect, opensDrawer: Bool) {
            guard let previousFrames else { return }
            for (path, card) in cards where viewport.intersects(card.frame) {
                let frame = card.frame.offsetBy(dx: -viewport.minX, dy: -viewport.minY)
                if previousFrames[path] != frame {
                    card.animateReflow(horizontalOffset: opensDrawer ? 12 : -12)
                }
            }
        }

        private func viewportAnchor(in viewport: CGRect) -> ViewportAnchor? {
            guard viewport.minY > 0.5, viewportSize.width > 0 else { return nil }
            let oldViewport = CGRect(origin: viewport.origin, size: viewportSize)
            if let selectedID, let path = indexPaths[selectedID], let frame = layout.itemFrame(at: path),
               frame.intersects(oldViewport) {
                return ViewportAnchor(id: selectedID, offset: frame.minY - oldViewport.minY)
            }
            guard let path = layout.itemPaths(in: oldViewport, reverse: false).first,
                  let poster = poster(at: path), let frame = layout.itemFrame(at: path) else { return nil }
            return ViewportAnchor(id: poster.id, offset: frame.minY - oldViewport.minY)
        }

        private func restoredY(for anchor: ViewportAnchor?, fallback: CGFloat) -> CGFloat {
            guard let anchor, let path = indexPaths[anchor.id], let frame = layout.itemFrame(at: path)
            else { return fallback }
            return frame.minY - anchor.offset
        }

        private func setScrollPosition(_ y: CGFloat, in scrollView: NSScrollView) {
            let clip = scrollView.contentView
            let maxY = max(0, layout.contentHeight - clip.bounds.height)
            let clamped = min(max(0, y), maxY)
            if abs(clip.bounds.minY - clamped) > 0.5 {
                clip.scroll(to: NSPoint(x: 0, y: clamped))
                scrollView.reflectScrolledClipView(clip)
            }
        }

        private func clipBoundsChanged() {
            guard !boundsObservationSuspended, scrollView?.contentView.bounds.size == viewportSize else { return }
            updateMountedViews(force: false, reconfigure: false)
            updatePrefetchPlanIfNeeded()
        }

        func detach() {
            legacyScrollEnd?.cancel()
            stopPrefetching()
            for card in cards.values { card.recycle() }
        }

        private func hasSamePositions(as oldSections: [ShelfSectionModel]) -> Bool {
            guard oldSections.count == sections.count else { return false }
            return zip(oldSections, sections).allSatisfy { old, new in
                old.status == new.status && old.isCollapsed == new.isCollapsed
                    && old.visibleCount == new.visibleCount
                    && (new.isCollapsed || zip(old.items, new.items).allSatisfy { $0.id == $1.id })
            }
        }

        private func rebuildIndexPaths() {
            indexPaths.removeAll(keepingCapacity: true)
            indexPaths.reserveCapacity(sections.reduce(0) { $0 + $1.visibleCount })
            for (index, section) in sections.enumerated() where !section.isCollapsed {
                for (offset, item) in section.items.enumerated() where indexPaths[item.id] == nil {
                    indexPaths[item.id] = IndexPath(item: offset, section: index)
                }
            }
        }

        private func poster(at path: IndexPath) -> LibraryPoster? {
            guard sections.indices.contains(path.section) else { return nil }
            let section = sections[path.section]
            return (0..<section.visibleCount).contains(path.item) ? section.items[path.item] : nil
        }

        private func updateMountedViews(force: Bool, reconfigure: Bool) {
            guard let gridView, let viewport = scrollView?.contentView.bounds, viewport.height > 0 else { return }
            let step = layout.rowStep
            guard step > 0 else { return }
            // Retain an extra row on each side so scroll events only move already attached layers.
            let top = (viewport.minY / step).rounded(.down) * step - step
            let bottom = (viewport.maxY / step).rounded(.up) * step + step
            let area = CGRect(x: 0, y: top, width: viewport.width, height: bottom - top)
            guard force || mountedArea != area else { return }
            mountedArea = area

            var positions: [(IndexPath, CGRect)] = []
            layout.visitItems(in: area) { positions.append(($0, $1)) }
            let wanted = Set(positions.map(\.0))
            for (path, card) in cards where !wanted.contains(path) {
                if activeHoveredView === card { clearHoveredCell(animated: false) }
                card.recycle()
                card.removeFromSuperview()
                cards.removeValue(forKey: path)
                recycledCards.append(card)
            }

            for (path, frame) in positions {
                if let card = cards[path] {
                    if force {
                        if card.frame.size != frame.size {
                            card.frame = frame
                        } else if card.frame.origin != frame.origin {
                            card.setFrameOrigin(frame.origin)
                        }
                        if reconfigure, let poster = poster(at: path) { configure(card, for: poster) }
                    }
                } else {
                    guard let poster = poster(at: path) else { continue }
                    let card = recycledCards.popLast() ?? PosterCardInteractiveView()
                    card.frame = frame
                    configure(card, for: poster)
                    gridView.addSubview(card)
                    cards[path] = card
                }
            }

            let headerFrames = layout.headers(in: area)
            let visibleHeaders = Set(headerFrames.map(\.0))
            for (index, header) in headers where !visibleHeaders.contains(index) {
                header.removeFromSuperview()
                headers.removeValue(forKey: index)
                recycledHeaders.append(header)
            }
            for (index, frame) in headerFrames {
                if let header = headers[index] {
                    if force {
                        if header.frame != frame { header.frame = frame }
                        if reconfigure { configure(header, section: index) }
                    }
                } else {
                    let header = recycledHeaders.popLast() ?? ShelfSectionHeaderView()
                    header.frame = frame
                    configure(header, section: index)
                    gridView.addSubview(header)
                    headers[index] = header
                }
            }
            // An unusually large window should not leave an equally large reuse pool.
            if recycledCards.count > 16 { recycledCards.removeLast(recycledCards.count - 16) }
        }

        private func updatePrefetchPlanIfNeeded() {
            guard let visible = scrollView?.contentView.bounds else { return }
            if let anchor = prefetchAnchor, anchor.size == visible.size,
               abs(anchor.minY - visible.minY) < 32 { return }
            updatePrefetchPlan()
        }

        private func updatePrefetchPlan() {
            guard let clip = scrollView?.contentView, clip.bounds.height > 0 else { return }
            let viewport = clip.bounds
            if let anchor = prefetchAnchor, abs(anchor.minY - viewport.minY) > 1 {
                movingUp = viewport.minY < anchor.minY
            }
            let reach = viewport.height * 1.75
            let above = CGRect(x: viewport.minX, y: viewport.minY - reach,
                               width: viewport.width, height: reach)
            let below = CGRect(x: viewport.minX, y: viewport.maxY,
                               width: viewport.width, height: reach)
            let upcoming = layout.itemPaths(in: movingUp ? above : below, reverse: movingUp)
            let behind = layout.itemPaths(in: movingUp ? below : above, reverse: !movingUp)
            let onScreen = layout.itemPaths(in: viewport, reverse: movingUp)

            guard !onScreen.isEmpty || !upcoming.isEmpty || !behind.isEmpty else { return }
            prefetchAnchor = viewport

            // A row that intersects the viewport boundary belongs to both lists.
            var seen = Set<CoverManager.Request>()
            var next: [CoverManager.Request] = []
            let prioritized = [Array(upcoming.prefix(12)), onScreen, Array(upcoming.dropFirst(12)), behind]
            for paths in prioritized {
                for path in paths where next.count < 36 {
                    guard let item = poster(at: path) else { continue }
                    let request = item.artworkRequest(language: parent.language)
                    if seen.insert(request).inserted { next.append(request) }
                }
            }
            if next != prefetchPlan {
                prefetchPlan = next
                CoverManager.shared.setPrefetchPlan(next, for: prefetchOwner)
            }
        }

        func stopPrefetching() {
            prefetchAnchor = nil
            movingUp = false
            if !prefetchPlan.isEmpty {
                prefetchPlan.removeAll(keepingCapacity: true)
                CoverManager.shared.setPrefetchPlan([], for: prefetchOwner)
            }
        }

        private func configure(_ card: PosterCardInteractiveView, for item: LibraryPoster) {
            card.configure(item: item, isSelected: selectedID == item.id,
                           showStatusBadge: parent.showStatusBadges, language: parent.language, coordinator: self)
        }

        private func configure(_ header: ShelfSectionHeaderView, section: Int) {
            guard sections.indices.contains(section) else { return }
            let model = sections[section]
            header.configure(section: model, isFirstSection: section == 0, language: parent.language,
                             onToggleCollapse: { [weak self, status = model.status] in
                                 if let status { self?.parent.onToggleSectionCollapse(status) }
                             },
                             onQuickAdd: { [weak self, status = model.status] in
                                 if let status { self?.parent.onQuickAddInSection(status) }
                             })
        }

        // MARK: Keyboard Navigation & Quick Actions

        func editSelectedItem() {
            guard let id = selectedID, indexPaths[id] != nil else { return }
            parent.onDoubleClickEdit(id)
        }

        func select(_ id: UUID, toggling: Bool = false) {
            let previous = selectedID
            selectedID = toggling && previous == id ? nil : id
            if toggling { parent.onSelectItem(id) }
            else { parent.onEnsureSelectItem(id) }
            updateSelectionAppearance(from: previous, to: selectedID)
        }

        func deselect() {
            let previous = selectedID
            selectedID = nil
            parent.onDeselectAll()
            updateSelectionAppearance(from: previous, to: nil)
        }

        func navigateSelection(keyCode: UInt16) -> Bool {
            guard let gridView,
                  let first = sections.firstIndex(where: { $0.visibleCount > 0 }) else { return false }
            let target: IndexPath?
            if let id = selectedID, let current = indexPaths[id] {
                switch keyCode {
                case 123: target = neighboringItem(from: current, direction: -1) ?? current
                case 124: target = neighboringItem(from: current, direction: 1) ?? current
                case 125: target = layout.itemInAdjacentRow(from: current, direction: 1)
                case 126: target = layout.itemInAdjacentRow(from: current, direction: -1)
                default: return false
                }
            } else {
                target = IndexPath(item: 0, section: first)
            }
            if let target, let item = poster(at: target) {
                select(item.id)
                if let frame = layout.itemFrame(at: target) {
                    gridView.scrollToVisible(frame.insetBy(dx: 0, dy: -20))
                }
            }
            return true
        }

        private func neighboringItem(from path: IndexPath, direction: Int) -> IndexPath? {
            var section = path.section
            let offset = path.item + direction
            if (0..<sections[section].visibleCount).contains(offset) {
                return IndexPath(item: offset, section: section)
            }
            repeat {
                section += direction
                guard sections.indices.contains(section) else { return nil }
            } while sections[section].visibleCount == 0
            return IndexPath(item: direction > 0 ? 0 : sections[section].visibleCount - 1, section: section)
        }

    }
}

@MainActor
final class PosterGridView: NSView {
    weak var coordinator: NativePosterGrid.Coordinator?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityRole(.group)
        addTrackingArea(NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseMoved(with event: NSEvent) {
        guard let coordinator, !coordinator.isLiveScrolling else { return }
        coordinator.refreshHoverAtCurrentMouseLocation(event.locationInWindow)
    }

    override func mouseEntered(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        coordinator?.clearHoveredCell(animated: true)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        coordinator?.deselect()
    }

    override func cancelOperation(_ sender: Any?) {
        coordinator?.deselect()
    }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.intersection([.command, .option, .control]).isEmpty {
            switch event.keyCode {
            case 53: // Esc
                coordinator?.deselect()
                return
            case 36, 76: // Return / Enter
                coordinator?.editSelectedItem()
                return
            case 123, 124, 125, 126: // Arrow keys
                if coordinator?.navigateSelection(keyCode: event.keyCode) == true {
                    return
                }
            default:
                break
            }
        }
        super.keyDown(with: event)
    }
}

// MARK: - Section Header

@MainActor
private final class ShelfSectionHeaderView: NSView {

    private let toggleContainer = NSView()
    private let chevronImageView = NSImageView()
    private let dotLayer = CALayer()
    private let titleLabel = NSTextField(labelWithString: "")
    private let countBadgeContainer = NSView()
    private let countLabel = NSTextField(labelWithString: "")
    private let dividerLine = NSView()
    private let addButton = HeaderPlusButton()

    private var onToggle: (() -> Void)?
    private var isToggleHovered = false
    private var toggleTrackingArea: NSTrackingArea?
    private var topOffset: CGFloat = 6

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setupViews()
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        toggleContainer.wantsLayer = true
        toggleContainer.layer?.cornerRadius = 7
        toggleContainer.layer?.cornerCurve = .continuous
        addSubview(toggleContainer)

        chevronImageView.imageScaling = .scaleProportionallyDown
        chevronImageView.contentTintColor = .secondaryLabelColor
        toggleContainer.addSubview(chevronImageView)

        dotLayer.cornerRadius = 4
        toggleContainer.layer?.addSublayer(dotLayer)

        titleLabel.font = .systemFont(ofSize: 14, weight: .bold)
        titleLabel.textColor = .labelColor.withAlphaComponent(0.92)
        titleLabel.lineBreakMode = .byTruncatingTail
        toggleContainer.addSubview(titleLabel)

        countBadgeContainer.wantsLayer = true
        countBadgeContainer.layer?.cornerRadius = 8.5
        countBadgeContainer.layer?.cornerCurve = .continuous
        toggleContainer.addSubview(countBadgeContainer)

        countLabel.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .center
        countBadgeContainer.addSubview(countLabel)

        dividerLine.wantsLayer = true
        addSubview(dividerLine)

        addSubview(addButton)
        refreshDynamicColors()
    }

    func configure(
        section: ShelfSectionModel,
        isFirstSection: Bool,
        language: AppLanguage,
        onToggleCollapse: @escaping () -> Void,
        onQuickAdd: @escaping () -> Void
    ) {
        self.onToggle = onToggleCollapse
        self.topOffset = isFirstSection ? 10 : 6

        let symbolName = section.isCollapsed ? "chevron.right" : "chevron.down"
        let cfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .bold)
        chevronImageView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dotLayer.backgroundColor = (section.status?.nsTintColor ?? .systemBlue).cgColor
        CATransaction.commit()

        titleLabel.stringValue = section.title
        countLabel.stringValue = "\(section.totalCount)"
        setAccessibilityLabel("\(section.title), \(section.totalCount)")
        setAccessibilityValue(section.isCollapsed
            ? language.tr("已折叠", "Collapsed") : language.tr("已展开", "Expanded"))

        let addTitle = language.tr("添加到「\(section.title)」", "Add to \(section.title)")
        addButton.toolTip = addTitle
        addButton.setAccessibilityLabel(addTitle)
        addButton.onClick = onQuickAdd

        needsLayout = true
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onToggle else { return false }
        onToggle()
        return true
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        let centerY = topOffset + (h - topOffset) * 0.5

        titleLabel.sizeToFit()
        countLabel.sizeToFit()

        let badgeW = max(22, ceil(countLabel.frame.width) + 14)
        let badgeH: CGFloat = 17
        let toggleW = 8 + 12 + 7 + 8 + 8 + ceil(titleLabel.frame.width) + 8 + badgeW + 8
        let toggleH: CGFloat = 28

        toggleContainer.frame = NSRect(x: -6, y: round(centerY - toggleH * 0.5), width: toggleW, height: toggleH)

        chevronImageView.frame = NSRect(x: 8, y: round((toggleH - 12) * 0.5), width: 12, height: 12)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dotLayer.frame = CGRect(x: 27, y: round((toggleH - 8) * 0.5), width: 8, height: 8)
        CATransaction.commit()

        titleLabel.frame = NSRect(
            x: 43,
            y: round((toggleH - titleLabel.frame.height) * 0.5),
            width: ceil(titleLabel.frame.width),
            height: ceil(titleLabel.frame.height)
        )

        let badgeX = titleLabel.frame.maxX + 8
        countBadgeContainer.frame = NSRect(x: badgeX, y: round((toggleH - badgeH) * 0.5), width: badgeW, height: badgeH)
        countLabel.frame = NSRect(
            x: 0,
            y: round((badgeH - countLabel.frame.height) * 0.5),
            width: badgeW,
            height: ceil(countLabel.frame.height)
        )

        let addSize: CGFloat = 24
        addButton.frame = NSRect(
            x: bounds.width - addSize,
            y: round(centerY - addSize * 0.5),
            width: addSize,
            height: addSize
        )

        let lineX = toggleContainer.frame.maxX + 10
        let lineRight = addButton.frame.minX - 10
        if lineRight > lineX {
            dividerLine.isHidden = false
            dividerLine.frame = NSRect(x: lineX, y: round(centerY), width: lineRight - lineX, height: 1)
        } else {
            dividerLine.isHidden = true
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let toggleTrackingArea {
            removeTrackingArea(toggleTrackingArea)
        }
        let area = NSTrackingArea(
            rect: toggleContainer.frame,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        toggleTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isToggleHovered = true
        refreshDynamicColors()
    }

    override func mouseExited(with event: NSEvent) {
        isToggleHovered = false
        refreshDynamicColors()
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if toggleContainer.frame.contains(pt) {
            onToggle?()
        } else {
            super.mouseDown(with: event)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshDynamicColors()
    }

    private func refreshDynamicColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            toggleContainer.layer?.backgroundColor = isToggleHovered
                ? NSColor.labelColor.withAlphaComponent(0.06).cgColor
                : NSColor.clear.cgColor
            countBadgeContainer.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
            dividerLine.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.09).cgColor
        }
    }
}

@MainActor
private final class HeaderPlusButton: NSView {
    private let iconView = NSImageView()
    private var isHovered = false
    private var isPressed = false
    var onClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous

        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        iconView.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        iconView.contentTintColor = .secondaryLabelColor
        addSubview(iconView)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)

        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        iconView.frame = bounds.insetBy(dx: 5, dy: 5)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressed = false
        updateAppearance()
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        updateAppearance()
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        updateAppearance()
        if inside {
            onClick?()
        }
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onClick else { return false }
        onClick()
        return true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            iconView.contentTintColor = isHovered ? .labelColor : .secondaryLabelColor
            if isPressed {
                layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.13).cgColor
            } else if isHovered {
                layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.07).cgColor
            } else {
                layer?.backgroundColor = NSColor.clear.cgColor
            }
        }
    }
}

// MARK: - Reused Poster Collection View Item

// MARK: - Pure CALayer GPU Poster Card View

@MainActor
final class PosterCardInteractiveView: NSView {
    private static let reflowAnimationKey = "drawerReflow"
    private let posterTransformView = NSView()
    private let shadowLayer = CALayer()
    private let artworkLayer = CALayer()
    private let spineSheenLayer = CAGradientLayer()
    private let borderLayer = CALayer()

    private var hoverSheenLayer: CAGradientLayer?
    private var badge: PosterStatusBadge?

    private var dropOverlay: NSView?
    private var dropLabel: NSTextField?

    private let titleLabel = NSTextField(labelWithString: "")
    private let starsLabel = NSTextField(labelWithString: "")

    private(set) var item: LibraryPoster?
    private weak var coordinator: NativePosterGrid.Coordinator?
    private var language: AppLanguage = .zh
    private var isCardSelected = false
    private var isHovered = false
    private var isPressed = false
    private var showStatusBadge = false
    private var artworkTask: Task<Void, Never>?
    private var artworkRequested = false
    private var lastPosterSize: CGSize = .zero
    private var placeholderDisplayed = false
    private var neededVisualReset = false
    private static let stars = (0...5).map { String(repeating: "★", count: $0) }

    override var isFlipped: Bool { true }

    var posterHitBounds: NSRect {
        let posterH = round(bounds.width * 1.5)
        return NSRect(x: 0, y: 0, width: bounds.width, height: min(bounds.height, posterH + 36))
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        clipsToBounds = false
        layer?.masksToBounds = false
        setupLayersAndSubviews()
        setAccessibilityElement(true)
        setAccessibilityRole(.button)

        registerForDraggedTypes([.fileURL, .png, .tiff, .URL, .string])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupLayersAndSubviews() {
        posterTransformView.wantsLayer = true
        posterTransformView.clipsToBounds = false
        posterTransformView.layer?.masksToBounds = false
        addSubview(posterTransformView)

        guard let rootPosterLayer = posterTransformView.layer else { return }

        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOpacity = 0.25
        shadowLayer.shadowRadius = 7.5
        shadowLayer.shadowOffset = CGSize(width: 0, height: 4)
        rootPosterLayer.addSublayer(shadowLayer)

        artworkLayer.cornerRadius = 10
        artworkLayer.cornerCurve = .continuous
        artworkLayer.masksToBounds = true
        artworkLayer.isOpaque = true
        artworkLayer.backgroundColor = NSColor(white: 0.09, alpha: 1.0).cgColor
        artworkLayer.contentsGravity = .resizeAspectFill
        artworkLayer.minificationFilter = .linear
        artworkLayer.magnificationFilter = .linear
        artworkLayer.actions = ["contents": NSNull()]
        rootPosterLayer.addSublayer(artworkLayer)

        spineSheenLayer.colors = [
            NSColor.white.withAlphaComponent(0.06).cgColor,
            NSColor.clear.cgColor,
            NSColor.black.withAlphaComponent(0.18).cgColor
        ]
        spineSheenLayer.startPoint = CGPoint(x: 0, y: 0)
        spineSheenLayer.endPoint = CGPoint(x: 1, y: 1)
        artworkLayer.addSublayer(spineSheenLayer)

        borderLayer.cornerRadius = 10
        borderLayer.cornerCurve = .continuous
        borderLayer.borderWidth = 0.75
        borderLayer.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        rootPosterLayer.addSublayer(borderLayer)

        titleLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.usesSingleLineMode = true
        addSubview(titleLabel)

        starsLabel.font = .systemFont(ofSize: 9.5, weight: .regular)
        starsLabel.textColor = NSColor(srgbRed: 0.96, green: 0.74, blue: 0.20, alpha: 1.0)
        starsLabel.alignment = .center
        starsLabel.usesSingleLineMode = true
        addSubview(starsLabel)
        updateTitleStyle()
    }

    private func makeDropOverlay() -> NSView {
        let dropOverlay = NSView()
        let dropLabel = NSTextField(labelWithString: "")
        dropOverlay.wantsLayer = true
        dropOverlay.layer?.cornerRadius = 10
        dropOverlay.layer?.cornerCurve = .continuous
        dropOverlay.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.36).cgColor
        dropOverlay.layer?.borderColor = NSColor.controlAccentColor.cgColor
        dropOverlay.layer?.borderWidth = 2.5
        posterTransformView.addSubview(dropOverlay)

        dropLabel.font = .systemFont(ofSize: 11, weight: .bold)
        dropLabel.textColor = .white
        dropLabel.alignment = .center
        dropLabel.wantsLayer = true
        dropLabel.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        dropLabel.layer?.cornerRadius = 6
        dropOverlay.addSubview(dropLabel)
        self.dropOverlay = dropOverlay
        self.dropLabel = dropLabel
        return dropOverlay
    }

    func recycle() {
        suspendArtwork()
        cancelReflowAnimation()
        if coordinator?.activeHoveredView === self {
            coordinator?.clearHoveredCell(animated: false)
        }
        neededVisualReset = isHovered || isPressed
        isHovered = false
        isPressed = false
        dropOverlay?.isHidden = true
    }

    func animateReflow(horizontalOffset: CGFloat) {
        guard let layer else { return }
        let duration = 0.16
        let fade = CABasicAnimation(keyPath: "opacity")
        let currentOpacity = layer.animation(forKey: Self.reflowAnimationKey) != nil ? layer.presentation()?.opacity : nil
        fade.fromValue = currentOpacity ?? 0.66
        fade.toValue = 1
        fade.duration = duration

        let slide = CABasicAnimation(keyPath: "transform.translation.x")
        slide.isAdditive = true
        slide.fromValue = horizontalOffset
        slide.toValue = 0
        slide.duration = duration

        let animation = CAAnimationGroup()
        animation.animations = [fade, slide]
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(animation, forKey: Self.reflowAnimationKey)
    }

    func cancelReflowAnimation() {
        layer?.removeAnimation(forKey: Self.reflowAnimationKey)
    }

    func configure(
        item: LibraryPoster,
        isSelected: Bool,
        showStatusBadge: Bool,
        language: AppLanguage,
        coordinator: NativePosterGrid.Coordinator
    ) {
        self.coordinator = coordinator
        let previous = self.item
        let oldLanguage = self.language
        let badgeChanged = self.showStatusBadge != showStatusBadge
        self.showStatusBadge = showStatusBadge
        self.language = language
        self.item = item

        if previous != item || oldLanguage != language {
            if previous?.title != item.title {
                titleLabel.stringValue = item.title
                setAccessibilityLabel(item.title)
            }
            if previous?.rating != item.rating {
                starsLabel.stringValue = Self.stars[item.rating]
                starsLabel.isHidden = item.rating == 0
            }
            if previous?.category != item.category || previous?.status != item.status || oldLanguage != language {
                if showStatusBadge || isHovered { updateStatusBadge() }
            }

            let placeholderChanged = previous?.title != item.title || previous?.subtag != item.subtag
                || previous?.category != item.category || previous?.paletteSeed != item.paletteSeed
                || oldLanguage != language
            if previous?.coverFileName != item.coverFileName || !artworkRequested
                || ((placeholderDisplayed || artworkTask != nil) && placeholderChanged) {
                suspendArtwork()
                resumeArtwork()
            }
        } else if !artworkRequested {
            resumeArtwork()
        }
        if isCardSelected != isSelected || badgeChanged || previous == nil || neededVisualReset {
            neededVisualReset = false
            if isCardSelected != isSelected {
                isCardSelected = isSelected
                setAccessibilitySelected(isSelected)
                updateTitleStyle()
            }
            refreshVisualState(animated: false)
            needsLayout = true
        }
    }

    func suspendArtwork() {
        cancelPendingArtwork()
        showArtwork(nil)
        artworkRequested = false
        placeholderDisplayed = false
    }

    func cancelPendingArtwork() {
        guard artworkTask != nil else { return }
        artworkTask?.cancel()
        artworkTask = nil
        artworkRequested = false
    }

    func resumeArtwork() {
        guard let item, !artworkRequested else { return }
        artworkRequested = true
        let manager = CoverManager.shared
        let request = item.artworkRequest(language: language)
        if let artwork = manager.cachedArtwork(for: request) {
            placeholderDisplayed = request.fileName == nil
            showArtwork(artwork)
            return
        }
        artworkTask = Task { [weak self] in
            let decoded = await manager.artwork(for: request)
            guard !Task.isCancelled else { return }
            if let decoded {
                self?.placeholderDisplayed = request.fileName == nil
                self?.showArtwork(decoded)
            } else if request.fileName != nil, let self {
                let image = await manager.artwork(for: item.placeholderRequest(language: self.language))
                guard !Task.isCancelled else { return }
                self.placeholderDisplayed = true
                self.showArtwork(image)
            }
            self?.artworkTask = nil
        }
    }

    private func showArtwork(_ artwork: CoverManager.Artwork?) {
        artworkLayer.contents = artwork?.contents
    }

    func setSelected(_ selected: Bool) {
        guard isCardSelected != selected else { return }
        isCardSelected = selected
        setAccessibilitySelected(selected)
        updateTitleStyle()
        refreshVisualState(animated: false)
    }

    func setHovered(_ hovered: Bool, animated: Bool) {
        guard isHovered != hovered else { return }
        isHovered = hovered
        refreshVisualState(animated: animated)
        needsLayout = true
    }

    private func refreshVisualState(animated: Bool) {
        let moves = coordinator?.reduceMotion != true && coordinator?.isLiveScrolling != true
        effectiveAppearance.performAsCurrentDrawingAppearance {
            updateStatusBadge()

            let borderCol: CGColor = isCardSelected
                ? NSColor.controlAccentColor.cgColor
                : NSColor.white.withAlphaComponent(isHovered ? 0.36 : 0.16).cgColor
            let borderW: CGFloat = isCardSelected ? 2.5 : (isHovered ? 1.2 : 0.75)

            let scale: CGFloat = moves ? (isPressed ? 0.976 : (isHovered ? 1.024 : 1.0)) : 1
            let liftY: CGFloat = moves && isHovered && !isPressed ? -2 : 0

            let w = max(1, posterTransformView.bounds.width)
            let h = max(1, posterTransformView.bounds.height)
            var t = CATransform3DIdentity
            if scale != 1.0 || liftY != 0.0 {
                t = CATransform3DTranslate(t, w * 0.5, h * 0.5 + liftY, 0)
                t = CATransform3DScale(t, scale, scale, 1.0)
                t = CATransform3DTranslate(t, -w * 0.5, -h * 0.5, 0)
            }

            CATransaction.begin()
            if animated && moves {
                CATransaction.setAnimationDuration(0.12)
                CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
            } else {
                CATransaction.setDisableActions(true)
                posterTransformView.layer?.removeAnimation(forKey: "transform")
                hoverSheenLayer?.removeAnimation(forKey: "opacity")
                borderLayer.removeAllAnimations()
            }
            borderLayer.borderColor = borderCol
            borderLayer.borderWidth = borderW
            if isHovered, hoverSheenLayer == nil {
                let sheen = CAGradientLayer()
                sheen.colors = [NSColor.white.withAlphaComponent(0.15).cgColor,
                                NSColor.white.withAlphaComponent(0.02).cgColor, NSColor.clear.cgColor]
                sheen.startPoint = .zero
                sheen.endPoint = CGPoint(x: 1, y: 1)
                sheen.frame = artworkLayer.bounds
                artworkLayer.addSublayer(sheen)
                hoverSheenLayer = sheen
            }
            hoverSheenLayer?.opacity = isHovered ? 1 : 0
            posterTransformView.layer?.transform = t
            layer?.zPosition = isHovered ? 20 : (isCardSelected ? 5 : 0)
            CATransaction.commit()
        }
    }

    private func updateTitleStyle() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            titleLabel.font = .systemFont(ofSize: 12.5, weight: isCardSelected ? .semibold : .medium)
            titleLabel.textColor = isCardSelected
                ? .controlAccentColor : NSColor.labelColor.withAlphaComponent(0.92)
        }
    }

    private func updateStatusBadge() {
        guard let item, showStatusBadge || isHovered else {
            badge?.isHidden = true
            return
        }
        let badge: PosterStatusBadge
        if let existing = self.badge {
            badge = existing
        } else {
            badge = PosterStatusBadge()
            if let dropOverlay {
                posterTransformView.addSubview(badge, positioned: .below, relativeTo: dropOverlay)
            } else {
                posterTransformView.addSubview(badge)
            }
            self.badge = badge
        }
        let wasHidden = badge.isHidden
        badge.isHidden = false
        let oldWidth = badge.pillWidth
        badge.configure(text: item.category.statusLabel(for: item.status, in: language), status: item.status)
        if wasHidden || oldWidth != badge.pillWidth { needsLayout = true }
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        guard w > 10 else { return }
        let posterH = round(w * 1.5)
        let posterRect = NSRect(x: 0, y: 0, width: w, height: posterH)

        if lastPosterSize != posterRect.size {
            lastPosterSize = posterRect.size
            posterTransformView.frame = posterRect
            let posterBounds = posterTransformView.bounds
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            shadowLayer.frame = posterBounds
            shadowLayer.shadowPath = CGPath(
                roundedRect: posterBounds,
                cornerWidth: 10,
                cornerHeight: 10,
                transform: nil
            )
            artworkLayer.frame = posterBounds
            spineSheenLayer.frame = artworkLayer.bounds
            hoverSheenLayer?.frame = artworkLayer.bounds
            borderLayer.frame = posterBounds
            CATransaction.commit()
            dropOverlay?.frame = posterBounds
            titleLabel.frame = NSRect(x: 2, y: posterH + 8, width: max(0, w - 4), height: 17)
            starsLabel.frame = NSRect(x: 2, y: posterH + 25, width: max(0, w - 4), height: 13)
        }

        // Layout top-right status badge
        if let badge, !badge.isHidden {
            let width = badge.pillWidth
            badge.frame = NSRect(x: w - width - 7, y: 7, width: width, height: 19)
        }

        if let dropOverlay, !dropOverlay.isHidden, let dropLabel {
            dropOverlay.frame = posterTransformView.bounds
            let dw = max(0, min(w - 16, ceil(dropLabel.intrinsicContentSize.width) + 18))
            let dh: CGFloat = 24
            dropLabel.frame = NSRect(x: round((w - dw) * 0.5), y: round((posterH - dh) * 0.5), width: dw, height: dh)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateTitleStyle()
        refreshVisualState(animated: false)
    }

    // MARK: - Pointer & Click Handling

    override func accessibilityPerformPress() -> Bool {
        guard let item, let coordinator else { return false }
        coordinator.select(item.id, toggling: true)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        guard let item, let coordinator else { return }
        if let grid = coordinator.gridView {
            window?.makeFirstResponder(grid)
        }
        if event.clickCount >= 2 {
            isPressed = false
            refreshVisualState(animated: false)
            coordinator.select(item.id)
            coordinator.parent.onDoubleClickEdit(item.id)
        } else {
            isPressed = true
            refreshVisualState(animated: true)
            coordinator.select(item.id, toggling: true)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard isPressed else { return }
        isPressed = false
        refreshVisualState(animated: true)
    }

    // MARK: - Native Context Menu (Built On-Demand Only When Right-Clicked)

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let item, let coordinator else { return nil }
        let lang = language
        if let grid = coordinator.gridView {
            window?.makeFirstResponder(grid)
        }
        coordinator.select(item.id)

        let menu = NSMenu()

        // Status section
        let statusHeader = NSMenuItem.sectionHeader(title: lang.tr("切换状态", "Status"))
        menu.addItem(statusHeader)
        for st in TrackingStatus.filterOrder {
            let mi = ActionMenuItem(
                title: item.category.statusLabel(for: st, in: lang)
            ) { [weak coordinator] in
                coordinator?.parent.onChangeStatus(item.id, st)
            }
            mi.state = (item.status == st) ? .on : .off
            mi.image = NSImage(systemSymbolName: st.systemImage, accessibilityDescription: nil)
            menu.addItem(mi)
        }

        menu.addItem(.separator())

        // Rating section
        menu.addItem(NSMenuItem.sectionHeader(title: lang.tr("快速评分", "Quick Rating")))
        for stars in [5, 4, 3, 2, 1] {
            let label = String(repeating: "★", count: stars) + String(repeating: "☆", count: 5 - stars)
            let mi = ActionMenuItem(title: label) { [weak coordinator] in
                coordinator?.parent.onChangeRating(item.id, stars)
            }
            mi.state = (item.rating == stars) ? .on : .off
            menu.addItem(mi)
        }
        if item.rating > 0 {
            menu.addItem(
                ActionMenuItem(title: lang.tr("清除评分", "Clear Rating")) { [weak coordinator] in
                    coordinator?.parent.onChangeRating(item.id, 0)
                }
            )
        }

        menu.addItem(.separator())

        // Cover & Edit section
        menu.addItem(NSMenuItem.sectionHeader(title: lang.tr("封面与编辑", "Cover & Edit")))

        let replaceItem = ActionMenuItem(title: lang.tr("更换封面…", "Change Cover…")) { [weak coordinator] in
            coordinator?.parent.onRequestReplaceCover(item.id)
        }
        replaceItem.image = NSImage(systemSymbolName: "photo.on.rectangle.angled", accessibilityDescription: nil)
        menu.addItem(replaceItem)

        let localItem = ActionMenuItem(title: lang.tr("选择本地图片…", "Choose Local Image…")) { [weak coordinator] in
            guard let coordinator, let url = CoverManager.shared.chooseLocalImagePanel(lang: lang) else { return }
            coordinator.parent.onImportCover(item.id, .file(url))
        }
        localItem.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        menu.addItem(localItem)

        let pasteItem = ActionMenuItem(title: lang.tr("从剪贴板粘贴封面", "Paste Cover from Clipboard")) { [weak coordinator] in
            guard let coordinator else { return }
            if let source = CoverManager.shared.inspectPasteboard() {
                coordinator.parent.onImportCover(item.id, source)
            } else {
                coordinator.parent.onShowToast(
                    lang.tr("剪贴板中没有检测到图片或图片链接", "No image or image URL found in clipboard")
                )
            }
        }
        pasteItem.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)
        menu.addItem(pasteItem)

        if item.coverFileName != nil {
            let resetCoverItem = ActionMenuItem(title: lang.tr("恢复默认封面", "Reset Default Cover")) { [weak coordinator] in
                coordinator?.parent.onUpdateCoverFileName(item.id, nil)
            }
            resetCoverItem.image = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: nil)
            menu.addItem(resetCoverItem)
        }

        menu.addItem(.separator())

        let tagsItem = ActionMenuItem(title: lang.tr("设置标签…", "Tags…")) { [weak coordinator] in
            coordinator?.parent.onRequestEditTags(item.id)
        }
        tagsItem.image = NSImage(systemSymbolName: "tag", accessibilityDescription: nil)
        menu.addItem(tagsItem)

        let editItem = ActionMenuItem(title: lang.tr("编辑作品信息…", "Edit Info…")) { [weak coordinator] in
            coordinator?.parent.onDoubleClickEdit(item.id)
        }
        editItem.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: nil)
        menu.addItem(editItem)

        let deleteItem = ActionMenuItem(title: lang.tr("删除", "Delete")) { [weak coordinator] in
            coordinator?.parent.onDeleteItem(item.id)
        }
        deleteItem.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        menu.addItem(deleteItem)

        return menu
    }

    // MARK: - Drag & Drop Cover Replacement

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let overlay = dropOverlay ?? makeDropOverlay()
        dropLabel?.stringValue = language.tr("松开设为海报", "Drop to Set Cover")
        overlay.isHidden = false
        needsLayout = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropOverlay?.isHidden = true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        dropOverlay?.isHidden = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropOverlay?.isHidden = true
        guard let item, let coordinator else { return false }
        guard let source = CoverManager.shared.inspectPasteboard(sender.draggingPasteboard) else {
            coordinator.parent.onShowToast(CoverError.invalidImageData.message(in: language))
            return false
        }
        coordinator.parent.onImportCover(item.id, source)
        return true
    }
}

@MainActor
private final class PosterStatusBadge: NSView {
    private let dot = CALayer()
    private let label = NSTextField(labelWithString: "")
    private var status: TrackingStatus?
    var pillWidth: CGFloat { 24 + label.frame.width }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.68).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        layer?.borderWidth = 0.5
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = 9.5
        dot.cornerRadius = 3
        dot.frame = CGRect(x: 7, y: 6.5, width: 6, height: 6)
        dot.actions = ["backgroundColor": NSNull()]
        layer?.addSublayer(dot)
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .white
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(text: String, status: TrackingStatus) {
        if label.stringValue != text {
            label.stringValue = text
            let size = label.intrinsicContentSize
            label.frame = NSRect(x: 17, y: (19 - size.height) * 0.5,
                                 width: ceil(size.width), height: ceil(size.height))
        }
        if self.status != status {
            self.status = status
            dot.backgroundColor = status.nsTintColor.cgColor
        }
    }
}

private extension LibraryPoster {
    func artworkRequest(language: AppLanguage) -> CoverManager.Request {
        if let coverFileName, !coverFileName.isEmpty { return .thumbnail(coverFileName) }
        return placeholderRequest(language: language)
    }

    func placeholderRequest(language: AppLanguage) -> CoverManager.Request {
        .placeholder(PosterPlaceholder(title: title, category: category, subtag: subtag,
                                       paletteSeed: paletteSeed, language: language))
    }
}

@MainActor
private final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invokeAction), keyEquivalent: "")
        self.target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func invokeAction() {
        handler()
    }
}
