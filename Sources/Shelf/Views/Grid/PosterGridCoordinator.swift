import AppKit

extension NativePosterGrid {
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
        private let scrollController = GridScrollHoverController()
        private let prefetcher = GridArtworkPrefetcher()

        private var sections: [ShelfSectionModel] = []
        private var selectedID: UUID?
        private var indexPaths: [UUID: IndexPath] = [:]
        private var hasLoadedInitialData = false

        var isLiveScrolling: Bool { scrollController.isLiveScrolling }
        var reduceMotion = false {
            didSet {
                if reduceMotion && !oldValue {
                    for card in cards.values { card.cancelReflowAnimation() }
                }
            }
        }
        weak var activeHoveredView: PosterCardInteractiveView?

        init(parent: NativePosterGrid) {
            self.parent = parent
            super.init()
            scrollController.onStartLiveScroll = { [weak self] in
                self?.updatePrefetchPlan()
            }
            scrollController.onSuspendHover = { [weak self] in
                self?.clearHoveredCell(animated: true)
            }
            scrollController.onRestoreHover = { [weak self] in
                guard let self, self.gridView?.window?.isKeyWindow == true else { return }
                self.refreshHoverAtCurrentMouseLocation()
            }
            scrollController.onClipFrameChanged = { [weak self] in
                self?.clipFrameChanged()
            }
            scrollController.onClipBoundsChanged = { [weak self] in
                self?.clipBoundsChanged()
            }
        }

        func installScrollObservers(for scrollView: NSScrollView) {
            scrollController.install(for: scrollView)
        }

        func clearHoveredCell(animated: Bool) {
            activeHoveredView?.setHovered(false, animated: animated)
            activeHoveredView = nil
        }

        func refreshHoverAtCurrentMouseLocation(_ location: NSPoint? = nil) {
            guard !isLiveScrolling, let gridView, let window = gridView.window else { return }
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
            scrollController.scheduleHoverResume()
            updateMountedViews(force: false, reconfigure: false)
            updatePrefetchPlanIfNeeded()
        }

        func detach() {
            scrollController.detach()
            stopPrefetching()
            clearHoveredCell(animated: false)
            for card in cards.values {
                card.recycle()
                card.removeFromSuperview()
            }
            cards.removeAll()
            recycledCards.removeAll()
            for header in headers.values {
                header.recycle()
                header.removeFromSuperview()
            }
            headers.removeAll()
            recycledHeaders.removeAll()
            gridView?.coordinator = nil
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
            var reusable: [PosterCardInteractiveView] = []
            for (path, card) in cards where !wanted.contains(path) {
                if activeHoveredView === card { clearHoveredCell(animated: false) }
                card.recycle()
                cards.removeValue(forKey: path)
                reusable.append(card)
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
                    let card = reusable.popLast() ?? recycledCards.popLast() ?? PosterCardInteractiveView()
                    card.frame = frame
                    configure(card, for: poster)
                    if card.superview == nil { gridView.addSubview(card) }
                    cards[path] = card
                }
            }
            for card in reusable {
                card.removeFromSuperview()
                recycledCards.append(card)
            }

            let headerFrames = layout.headers(in: area)
            let visibleHeaders = Set(headerFrames.map(\.0))
            for (index, header) in headers where !visibleHeaders.contains(index) {
                header.recycle()
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
            if recycledCards.count > 16 { recycledCards.removeLast(recycledCards.count - 16) }
        }

        private func updatePrefetchPlanIfNeeded() {
            guard let visible = scrollView?.contentView.bounds else { return }
            prefetcher.updateIfNeeded(viewport: visible, layout: layout, language: parent.language) { [weak self] in
                self?.poster(at: $0)
            }
        }

        private func updatePrefetchPlan() {
            guard let visible = scrollView?.contentView.bounds else { return }
            prefetcher.update(viewport: visible, layout: layout, language: parent.language) { [weak self] in
                self?.poster(at: $0)
            }
        }

        func stopPrefetching() {
            prefetcher.stop()
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
                                 if let status { self?.parent.actions.onToggleSectionCollapse(status) }
                             },
                             onQuickAdd: { [weak self, status = model.status] in
                                 if let status { self?.parent.actions.onQuickAddInSection(status) }
                             })
        }

        // MARK: - Keyboard Navigation & Quick Actions

        func editSelectedItem() {
            guard let id = selectedID, indexPaths[id] != nil else { return }
            parent.actions.onDoubleClickEdit(id)
        }

        func select(_ id: UUID, toggling: Bool = false) {
            let previous = selectedID
            selectedID = toggling && previous == id ? nil : id
            if toggling { parent.actions.onSelectItem(id) }
            else { parent.actions.onEnsureSelectItem(id) }
            updateSelectionAppearance(from: previous, to: selectedID)
        }

        func deselect() {
            let previous = selectedID
            selectedID = nil
            parent.actions.onDeselectAll()
            updateSelectionAppearance(from: previous, to: nil)
        }

        func navigateSelection(keyCode: UInt16) -> Bool {
            guard let gridView,
                  let first = sections.firstIndex(where: { $0.visibleCount > 0 }) else { return false }
            let target: IndexPath?
            if let id = selectedID, let current = indexPaths[id] {
                switch keyCode {
                case PosterGridKeyCode.leftArrow: target = neighboringItem(from: current, direction: -1) ?? current
                case PosterGridKeyCode.rightArrow: target = neighboringItem(from: current, direction: 1) ?? current
                case PosterGridKeyCode.downArrow: target = layout.itemInAdjacentRow(from: current, direction: 1)
                case PosterGridKeyCode.upArrow: target = layout.itemInAdjacentRow(from: current, direction: -1)
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
