import AppKit
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

struct ShelfSectionModel: Equatable {
    let status: TrackingStatus?
    let title: String
    let totalCount: Int
    let isCollapsed: Bool
    let items: [MediaItem]
}

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

struct NativePosterCollectionView: NSViewRepresentable {
    let sections: [ShelfSectionModel]
    let selectedItemID: UUID?
    let showStatusBadges: Bool
    let posterScale: Double
    let language: AppLanguage
    let scrollResetToken: Int

    let onSelectItem: (MediaItem) -> Void
    let onEnsureSelectItem: (MediaItem) -> Void
    let onDeselectAll: () -> Void
    let onDoubleClickEdit: (MediaItem) -> Void
    let onRequestReplaceCover: (MediaItem) -> Void
    let onToggleSectionCollapse: (TrackingStatus) -> Void
    let onQuickAddInSection: (TrackingStatus) -> Void
    let onChangeStatus: (UUID, TrackingStatus) -> Void
    let onChangeRating: (UUID, Int) -> Void
    let onUpdateCoverFileName: (UUID, String?) -> Void
    let onDeleteItem: (UUID) -> Void
    let onShowToast: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator

        let initialRect = NSRect(x: 0, y: 0, width: 900, height: 640)
        let scrollView = NSScrollView(frame: initialRect)
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.usesPredominantAxisScrolling = true
        scrollView.borderType = .noBorder
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.contentView.postsFrameChangedNotifications = true

        let collectionView = KeyableCollectionView(frame: initialRect)
        collectionView.autoresizingMask = [.width]
        collectionView.collectionViewLayout = coordinator.makeCompositionalLayout()
        collectionView.backgroundColors = [.clear]
        collectionView.isSelectable = false
        collectionView.allowsMultipleSelection = false

        collectionView.register(
            PosterCollectionViewItem.self,
            forItemWithIdentifier: PosterCollectionViewItem.reuseIdentifier
        )
        collectionView.register(
            ShelfSectionHeaderView.self,
            forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
            withIdentifier: ShelfSectionHeaderView.reuseIdentifier
        )

        collectionView.dataSource = coordinator
        collectionView.delegate = coordinator
        collectionView.coordinator = coordinator
        scrollView.documentView = collectionView

        coordinator.scrollView = scrollView
        coordinator.collectionView = collectionView
        coordinator.installScrollObservers(for: scrollView)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        let oldSections = coordinator.parent.sections
        let oldScale = coordinator.parent.posterScale
        let oldLang = coordinator.parent.language
        let oldShowBadges = coordinator.parent.showStatusBadges
        let oldSelectedID = coordinator.parent.selectedItemID
        let oldResetToken = coordinator.parent.scrollResetToken

        coordinator.parent = self

        guard let collectionView = coordinator.collectionView else { return }

        let resetScroll = (oldResetToken != scrollResetToken)
        let dataChanged = !coordinator.hasLoadedInitialData
            || (oldSections != sections)
            || (oldLang != language)
            || (oldShowBadges != showStatusBadges)
        let scaleChanged = abs(oldScale - posterScale) > 0.0005

        if dataChanged {
            coordinator.hasLoadedInitialData = true
            let savedY = scrollView.contentView.bounds.origin.y
            coordinator.clearHoveredCell(animated: false)
            collectionView.reloadData()
            collectionView.layoutSubtreeIfNeeded()

            if resetScroll {
                scrollView.contentView.scroll(to: .zero)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            } else {
                let docHeight = collectionView.frame.height
                let clipHeight = scrollView.contentView.bounds.height
                let maxY = max(0, docHeight - clipHeight)
                let clampedY = min(max(0, savedY), maxY)
                if abs(scrollView.contentView.bounds.origin.y - clampedY) > 0.5 {
                    scrollView.contentView.scroll(to: NSPoint(x: 0, y: clampedY))
                    scrollView.reflectScrolledClipView(scrollView.contentView)
                }
            }
        } else {
            if scaleChanged {
                collectionView.collectionViewLayout?.invalidateLayout()
            }
            if oldSelectedID != selectedItemID {
                coordinator.updateSelectionAppearance(from: oldSelectedID, to: selectedItemID)
            }
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        var parent: NativePosterCollectionView
        weak var scrollView: NSScrollView?
        weak var collectionView: NSCollectionView?

        var hasLoadedInitialData: Bool = false
        private(set) var isLiveScrolling: Bool = false
        weak var activeHoveredView: PosterCardInteractiveView?

        private nonisolated(unsafe) var observers: [NSObjectProtocol] = []

        init(parent: NativePosterCollectionView) {
            self.parent = parent
        }

        deinit {
            for obs in observers {
                NotificationCenter.default.removeObserver(obs)
            }
        }

        func installScrollObservers(for scrollView: NSScrollView) {
            let nc = NotificationCenter.default
            let startObs = nc.addObserver(
                forName: NSScrollView.willStartLiveScrollNotification,
                object: scrollView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isLiveScrolling = true
                    self.clearHoveredCell(animated: false)
                }
            }

            let endObs = nc.addObserver(
                forName: NSScrollView.didEndLiveScrollNotification,
                object: scrollView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isLiveScrolling = false
                    self.refreshHoverAtCurrentMouseLocation()
                }
            }

            let frameObs = nc.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self,
                          let sv = self.scrollView,
                          let cv = self.collectionView else { return }
                    let clipW = sv.contentView.bounds.width
                    if clipW > 40 && abs(cv.frame.width - clipW) > 0.5 {
                        var f = cv.frame
                        f.size.width = clipW
                        cv.frame = f
                        cv.collectionViewLayout?.invalidateLayout()
                    }
                }
            }

            observers = [startObs, endObs, frameObs]
        }

        func clearHoveredCell(animated: Bool) {
            activeHoveredView?.setHovered(false, animated: animated)
            activeHoveredView = nil
        }

        private func refreshHoverAtCurrentMouseLocation() {
            guard let collectionView,
                  let window = collectionView.window else { return }
            let winPt = window.mouseLocationOutsideOfEventStream
            let cvPt = collectionView.convert(winPt, from: nil)
            guard collectionView.visibleRect.contains(cvPt),
                  let indexPath = collectionView.indexPathForItem(at: cvPt),
                  let cell = collectionView.item(at: indexPath) as? PosterCollectionViewItem
            else {
                return
            }
            let localPt = cell.cardView.convert(winPt, from: nil)
            if cell.cardView.posterHitBounds.contains(localPt) {
                activeHoveredView = cell.cardView
                cell.cardView.setHovered(true, animated: true)
            }
        }

        func updateSelectionAppearance(from oldID: UUID?, to newID: UUID?) {
            guard let collectionView else { return }
            for visibleItem in collectionView.visibleItems() {
                guard let cell = visibleItem as? PosterCollectionViewItem,
                      let itemID = cell.currentItem?.id else { continue }
                if itemID == oldID || itemID == newID {
                    cell.cardView.setSelected(itemID == newID)
                }
            }
        }

        // MARK: Compositional Layout

        func makeCompositionalLayout() -> NSCollectionViewCompositionalLayout {
            NSCollectionViewCompositionalLayout { [weak self] sectionIndex, layoutEnv in
                guard let self else { return nil }
                let sections = self.parent.sections
                guard sectionIndex >= 0 && sectionIndex < sections.count else { return nil }

                let sectionModel = sections[sectionIndex]
                let scale = self.parent.posterScale
                let minCardW = round(148 * scale)
                let maxCardW = round(186 * scale)
                let hSpacing = round(20 * max(0.85, scale * 0.95))
                let vSpacing = round(24 * max(0.88, scale * 0.95))

                let containerWidth = max(240, layoutEnv.container.effectiveContentSize.width)
                let horizontalPad: CGFloat = 24
                let availW = max(minCardW, containerWidth - horizontalPad * 2)

                let cols = max(1, Int(floor((availW + hSpacing) / (minCardW + hSpacing))))
                let rawCardW = floor((availW - CGFloat(cols - 1) * hSpacing) / CGFloat(cols))
                let cardW = cols == 1 ? min(maxCardW, rawCardW) : min(maxCardW + 24, rawCardW)
                let posterH = round(cardW * 1.5)
                let cellH = posterH + 40

                let itemSize = NSCollectionLayoutSize(
                    widthDimension: .absolute(cardW),
                    heightDimension: .absolute(cellH)
                )
                let layoutItem = NSCollectionLayoutItem(layoutSize: itemSize)

                let groupSize = NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1.0),
                    heightDimension: .absolute(sectionModel.isCollapsed ? 1 : cellH)
                )
                let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [layoutItem])
                group.interItemSpacing = .fixed(hSpacing)

                let section = NSCollectionLayoutSection(group: group)
                section.interGroupSpacing = vSpacing

                let isFirst = (sectionIndex == 0)
                let isLast = (sectionIndex == sections.count - 1)
                let hasHeader = (sectionModel.status != nil)

                let topInset: CGFloat = hasHeader ? (sectionModel.isCollapsed ? 0 : 12) : (isFirst ? 18 : 10)
                let bottomInset: CGFloat = isLast ? 34 : (sectionModel.isCollapsed ? 14 : 26)
                section.contentInsets = NSDirectionalEdgeInsets(
                    top: topInset,
                    leading: horizontalPad,
                    bottom: bottomInset,
                    trailing: horizontalPad
                )

                if hasHeader {
                    let headerSize = NSCollectionLayoutSize(
                        widthDimension: .fractionalWidth(1.0),
                        heightDimension: .absolute(isFirst ? 44 : 40)
                    )
                    let header = NSCollectionLayoutBoundarySupplementaryItem(
                        layoutSize: headerSize,
                        elementKind: NSCollectionView.elementKindSectionHeader,
                        alignment: .top
                    )
                    section.boundarySupplementaryItems = [header]
                }

                return section
            }
        }

        // MARK: NSCollectionViewDataSource

        func numberOfSections(in collectionView: NSCollectionView) -> Int {
            parent.sections.count
        }

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            guard section < parent.sections.count else { return 0 }
            let sec = parent.sections[section]
            return sec.isCollapsed ? 0 : sec.items.count
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            itemForRepresentedObjectAt indexPath: IndexPath
        ) -> NSCollectionViewItem {
            let cell = collectionView.makeItem(
                withIdentifier: PosterCollectionViewItem.reuseIdentifier,
                for: indexPath
            ) as! PosterCollectionViewItem

            let item = parent.sections[indexPath.section].items[indexPath.item]
            cell.configure(
                with: item,
                isSelected: parent.selectedItemID == item.id,
                showStatusBadge: parent.showStatusBadges,
                language: parent.language,
                coordinator: self
            )
            return cell
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
            at indexPath: IndexPath
        ) -> NSView {
            guard kind == NSCollectionView.elementKindSectionHeader else {
                return NSView()
            }
            let header = collectionView.makeSupplementaryView(
                ofKind: kind,
                withIdentifier: ShelfSectionHeaderView.reuseIdentifier,
                for: indexPath
            ) as! ShelfSectionHeaderView

            let sec = parent.sections[indexPath.section]
            header.configure(
                section: sec,
                isFirstSection: indexPath.section == 0,
                language: parent.language,
                onToggleCollapse: { [weak self] in
                    guard let self, let st = sec.status else { return }
                    self.parent.onToggleSectionCollapse(st)
                },
                onQuickAdd: { [weak self] in
                    guard let self, let st = sec.status else { return }
                    self.parent.onQuickAddInSection(st)
                }
            )
            return header
        }

        // MARK: Keyboard Navigation & Quick Actions

        func editSelectedItem() {
            guard let selectedID = parent.selectedItemID else { return }
            for sec in parent.sections where !sec.isCollapsed {
                if let match = sec.items.first(where: { $0.id == selectedID }) {
                    parent.onDoubleClickEdit(match)
                    return
                }
            }
        }

        func navigateSelection(keyCode: UInt16) -> Bool {
            guard let collectionView else { return false }

            var entries: [(indexPath: IndexPath, item: MediaItem)] = []
            for (secIdx, sec) in parent.sections.enumerated() where !sec.isCollapsed {
                for (itemIdx, item) in sec.items.enumerated() {
                    entries.append((IndexPath(item: itemIdx, section: secIdx), item))
                }
            }
            guard !entries.isEmpty else { return false }

            guard let currentSelectedID = parent.selectedItemID,
                  let currentIndex = entries.firstIndex(where: { $0.item.id == currentSelectedID })
            else {
                let first = entries[0]
                parent.onEnsureSelectItem(first.item)
                scrollItemIntoView(at: first.indexPath, in: collectionView)
                return true
            }

            let targetEntry: (indexPath: IndexPath, item: MediaItem)?
            switch keyCode {
            case 123: // Left
                targetEntry = currentIndex > 0 ? entries[currentIndex - 1] : entries[currentIndex]
            case 124: // Right
                targetEntry = currentIndex + 1 < entries.count ? entries[currentIndex + 1] : entries[currentIndex]
            case 125, 126: // Down (125) / Up (126)
                let movingDown = (keyCode == 125)
                if let currentFrame = collectionView.layoutAttributesForItem(at: entries[currentIndex].indexPath)?.frame {
                    let curMidX = currentFrame.midX
                    let curMidY = currentFrame.midY
                    var bestCandidate: (entry: (IndexPath, MediaItem), dy: CGFloat, dx: CGFloat)? = nil

                    for candidate in entries where candidate.item.id != currentSelectedID {
                        guard let frame = collectionView.layoutAttributesForItem(at: candidate.indexPath)?.frame else {
                            continue
                        }
                        let dy = frame.midY - curMidY
                        if movingDown && dy <= 12 { continue }
                        if !movingDown && dy >= -12 { continue }

                        let absDy = abs(dy)
                        let absDx = abs(frame.midX - curMidX)
                        if let best = bestCandidate {
                            if absDy < best.dy - 18 || (abs(absDy - best.dy) <= 18 && absDx < best.dx) {
                                bestCandidate = (candidate, absDy, absDx)
                            }
                        } else {
                            bestCandidate = (candidate, absDy, absDx)
                        }
                    }
                    targetEntry = bestCandidate?.entry
                } else {
                    targetEntry = nil
                }
            default:
                return false
            }

            if let target = targetEntry {
                parent.onEnsureSelectItem(target.item)
                scrollItemIntoView(at: target.indexPath, in: collectionView)
            }
            return true
        }

        private func scrollItemIntoView(at indexPath: IndexPath, in collectionView: NSCollectionView) {
            guard let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame else { return }
            let padded = frame.insetBy(dx: 0, dy: -20)
            collectionView.scrollToVisible(padded)
        }
    }
}

@MainActor
private final class KeyableCollectionView: NSCollectionView {
    weak var coordinator: NativePosterCollectionView.Coordinator?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let pt = convert(event.locationInWindow, from: nil)
        if indexPathForItem(at: pt) == nil {
            coordinator?.parent.onDeselectAll()
        } else {
            super.mouseDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        coordinator?.parent.onDeselectAll()
    }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.intersection([.command, .option, .control]).isEmpty {
            switch event.keyCode {
            case 53: // Esc
                coordinator?.parent.onDeselectAll()
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

// MARK: - Section Header Supplementary View

@MainActor
private final class ShelfSectionHeaderView: NSView, NSCollectionViewElement {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("ShelfSectionHeaderView")

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

        addButton.toolTip = language.tr("添加到「\(section.title)」", "Add to \(section.title)")
        addButton.onClick = onQuickAdd

        needsLayout = true
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

@MainActor
final class PosterCollectionViewItem: NSCollectionViewItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("PosterCollectionViewItem")

    let cardView = PosterCardInteractiveView()
    private(set) var currentItem: MediaItem?

    override func loadView() {
        self.view = cardView
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        currentItem = nil
        cardView.resetForReuse()
    }

    func configure(
        with item: MediaItem,
        isSelected: Bool,
        showStatusBadge: Bool,
        language: AppLanguage,
        coordinator: NativePosterCollectionView.Coordinator
    ) {
        self.currentItem = item
        cardView.configure(
            item: item,
            isSelected: isSelected,
            showStatusBadge: showStatusBadge,
            language: language,
            coordinator: coordinator
        )
    }
}

// MARK: - Pure CALayer GPU Poster Card View

@MainActor
final class PosterCardInteractiveView: NSView {
    private let posterTransformView = NSView()
    private let shadowLayer = CALayer()
    private let artworkLayer = CALayer()
    private let spineSheenLayer = CAGradientLayer()
    private let hoverSheenLayer = CAGradientLayer()
    private let borderLayer = CALayer()

    private let badgeContainer = NSView()
    private let badgeDotLayer = CALayer()
    private let badgeLabel = NSTextField(labelWithString: "")

    private let dropOverlay = NSView()
    private let dropLabel = NSTextField(labelWithString: "")

    private let titleLabel = NSTextField(labelWithString: "")
    private let starsLabel = NSTextField(labelWithString: "")

    private var item: MediaItem?
    private weak var coordinator: NativePosterCollectionView.Coordinator?
    private var language: AppLanguage = .zh
    private var isCardSelected = false
    private var isHovered = false
    private var isPressed = false
    private var showStatusBadge = false
    private var loadGeneration: UInt64 = 0
    private var lastShadowSize: CGSize = .zero

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

        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)

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

        let scaleFactor = NSScreen.main?.backingScaleFactor ?? 2.0
        artworkLayer.cornerRadius = 10
        artworkLayer.cornerCurve = .continuous
        artworkLayer.masksToBounds = true
        artworkLayer.isOpaque = true
        artworkLayer.backgroundColor = NSColor(white: 0.09, alpha: 1.0).cgColor
        artworkLayer.contentsGravity = .resizeAspectFill
        artworkLayer.contentsScale = scaleFactor
        artworkLayer.minificationFilter = .trilinear
        artworkLayer.magnificationFilter = .linear
        rootPosterLayer.addSublayer(artworkLayer)

        spineSheenLayer.colors = [
            NSColor.white.withAlphaComponent(0.06).cgColor,
            NSColor.clear.cgColor,
            NSColor.black.withAlphaComponent(0.18).cgColor
        ]
        spineSheenLayer.startPoint = CGPoint(x: 0, y: 0)
        spineSheenLayer.endPoint = CGPoint(x: 1, y: 1)
        artworkLayer.addSublayer(spineSheenLayer)

        hoverSheenLayer.colors = [
            NSColor.white.withAlphaComponent(0.15).cgColor,
            NSColor.white.withAlphaComponent(0.02).cgColor,
            NSColor.clear.cgColor
        ]
        hoverSheenLayer.startPoint = CGPoint(x: 0, y: 0)
        hoverSheenLayer.endPoint = CGPoint(x: 1, y: 1)
        hoverSheenLayer.opacity = 0
        artworkLayer.addSublayer(hoverSheenLayer)

        borderLayer.cornerRadius = 10
        borderLayer.cornerCurve = .continuous
        borderLayer.borderWidth = 0.75
        borderLayer.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        rootPosterLayer.addSublayer(borderLayer)

        // Top-right status pill
        badgeContainer.wantsLayer = true
        badgeContainer.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.68).cgColor
        badgeContainer.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        badgeContainer.layer?.borderWidth = 0.5
        badgeContainer.layer?.cornerCurve = .continuous
        posterTransformView.addSubview(badgeContainer)

        badgeDotLayer.cornerRadius = 3
        badgeContainer.layer?.addSublayer(badgeDotLayer)

        badgeLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        badgeLabel.textColor = .white
        badgeContainer.addSubview(badgeLabel)

        // Drag-and-drop highlight overlay
        dropOverlay.wantsLayer = true
        dropOverlay.layer?.cornerRadius = 10
        dropOverlay.layer?.cornerCurve = .continuous
        dropOverlay.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.36).cgColor
        dropOverlay.layer?.borderColor = NSColor.controlAccentColor.cgColor
        dropOverlay.layer?.borderWidth = 2.5
        dropOverlay.isHidden = true
        posterTransformView.addSubview(dropOverlay)

        dropLabel.font = .systemFont(ofSize: 11, weight: .bold)
        dropLabel.textColor = .white
        dropLabel.alignment = .center
        dropLabel.wantsLayer = true
        dropLabel.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        dropLabel.layer?.cornerRadius = 6
        dropOverlay.addSubview(dropLabel)

        // Title & stars below poster
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
    }

    func resetForReuse() {
        loadGeneration &+= 1
        if coordinator?.activeHoveredView === self {
            coordinator?.clearHoveredCell(animated: false)
        }
        isHovered = false
        isPressed = false
        dropOverlay.isHidden = true

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        posterTransformView.layer?.transform = CATransform3DIdentity
        hoverSheenLayer.opacity = 0
        artworkLayer.contents = nil
        CATransaction.commit()
    }

    func configure(
        item: MediaItem,
        isSelected: Bool,
        showStatusBadge: Bool,
        language: AppLanguage,
        coordinator: NativePosterCollectionView.Coordinator
    ) {
        self.item = item
        self.isCardSelected = isSelected
        self.showStatusBadge = showStatusBadge
        self.language = language
        self.coordinator = coordinator
        self.loadGeneration &+= 1
        let expectedGen = self.loadGeneration

        let displayTitle = item.displayTitle(in: language)
        titleLabel.stringValue = displayTitle
        starsLabel.stringValue = item.rating > 0 ? String(repeating: "★", count: item.rating) : ""
        starsLabel.isHidden = (item.rating <= 0)
        dropLabel.stringValue = language.tr("松开设为海报", "Drop to Set Cover")

        badgeLabel.stringValue = item.category.statusLabel(for: item.status, in: language)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        badgeDotLayer.backgroundColor = item.status.nsTintColor.cgColor

        if let coverFileName = item.coverFileName, !coverFileName.isEmpty {
            if let hit = CoverManager.shared.cachedGridCGImage(for: coverFileName) {
                artworkLayer.contents = hit
            } else {
                artworkLayer.contents = CoverManager.shared.editorialPlaceholderCGImage(
                    title: displayTitle,
                    category: item.category,
                    subtag: item.subtag,
                    paletteSeed: item.paletteSeed,
                    language: language
                )
                CoverManager.shared.loadGridCGImageAsync(for: coverFileName) { [weak self] decoded in
                    guard let self, self.loadGeneration == expectedGen, let decoded else { return }
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    self.artworkLayer.contents = decoded
                    CATransaction.commit()
                }
            }
        } else {
            artworkLayer.contents = CoverManager.shared.editorialPlaceholderCGImage(
                title: displayTitle,
                category: item.category,
                subtag: item.subtag,
                paletteSeed: item.paletteSeed,
                language: language
            )
        }
        CATransaction.commit()

        refreshVisualState(animated: false)
        needsLayout = true
    }

    func setSelected(_ selected: Bool) {
        guard isCardSelected != selected else { return }
        isCardSelected = selected
        refreshVisualState(animated: false)
    }

    func setHovered(_ hovered: Bool, animated: Bool) {
        guard isHovered != hovered else { return }
        isHovered = hovered
        refreshVisualState(animated: animated)
        needsLayout = true
    }

    private func refreshVisualState(animated: Bool) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            titleLabel.font = .systemFont(ofSize: 12.5, weight: isCardSelected ? .semibold : .medium)
            titleLabel.textColor = isCardSelected
                ? .controlAccentColor
                : NSColor.labelColor.withAlphaComponent(0.92)

            badgeContainer.isHidden = !(showStatusBadge || isHovered)
            badgeLabel.isHidden = !(showStatusBadge || isHovered)

            let borderCol: CGColor = isCardSelected
                ? NSColor.controlAccentColor.cgColor
                : NSColor.white.withAlphaComponent(isHovered ? 0.36 : 0.16).cgColor
            let borderW: CGFloat = isCardSelected ? 2.5 : (isHovered ? 1.2 : 0.75)

            let scale: CGFloat = isPressed ? 0.976 : (isHovered ? 1.024 : 1.0)
            let liftY: CGFloat = isHovered && !isPressed ? -2.0 : 0.0

            let w = max(1, posterTransformView.bounds.width)
            let h = max(1, posterTransformView.bounds.height)
            var t = CATransform3DIdentity
            if scale != 1.0 || liftY != 0.0 {
                t = CATransform3DTranslate(t, w * 0.5, h * 0.5 + liftY, 0)
                t = CATransform3DScale(t, scale, scale, 1.0)
                t = CATransform3DTranslate(t, -w * 0.5, -h * 0.5, 0)
            }

            CATransaction.begin()
            if animated {
                CATransaction.setAnimationDuration(0.14)
                CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
            } else {
                CATransaction.setDisableActions(true)
            }
            borderLayer.borderColor = borderCol
            borderLayer.borderWidth = borderW
            hoverSheenLayer.opacity = isHovered ? 1.0 : 0.0
            posterTransformView.layer?.transform = t
            layer?.zPosition = isHovered ? 20 : (isCardSelected ? 5 : 0)
            CATransaction.commit()
        }
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        guard w > 10 else { return }
        let posterH = round(w * 1.5)
        let posterRect = NSRect(x: 0, y: 0, width: w, height: posterH)

        posterTransformView.frame = posterRect

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shadowLayer.frame = posterTransformView.bounds
        if lastShadowSize != posterRect.size {
            lastShadowSize = posterRect.size
            shadowLayer.shadowPath = CGPath(
                roundedRect: posterTransformView.bounds,
                cornerWidth: 10,
                cornerHeight: 10,
                transform: nil
            )
        }
        artworkLayer.frame = posterTransformView.bounds
        spineSheenLayer.frame = artworkLayer.bounds
        hoverSheenLayer.frame = artworkLayer.bounds
        borderLayer.frame = posterTransformView.bounds
        CATransaction.commit()

        // Layout top-right status badge
        if !badgeContainer.isHidden {
            badgeLabel.sizeToFit()
            let textW = ceil(badgeLabel.frame.width)
            let pillW = 7 + 6 + 4 + textW + 7
            let pillH: CGFloat = 19
            badgeContainer.frame = NSRect(x: w - pillW - 7, y: 7, width: pillW, height: pillH)
            badgeContainer.layer?.cornerRadius = pillH * 0.5
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            badgeDotLayer.frame = CGRect(x: 7, y: round((pillH - 6) * 0.5), width: 6, height: 6)
            CATransaction.commit()
            badgeLabel.frame = NSRect(
                x: 17,
                y: round((pillH - badgeLabel.frame.height) * 0.5),
                width: textW,
                height: ceil(badgeLabel.frame.height)
            )
        }

        dropOverlay.frame = posterTransformView.bounds
        if !dropOverlay.isHidden {
            dropLabel.sizeToFit()
            let dw = min(w - 16, ceil(dropLabel.frame.width) + 18)
            let dh: CGFloat = 24
            dropLabel.frame = NSRect(x: round((w - dw) * 0.5), y: round((posterH - dh) * 0.5), width: dw, height: dh)
        }

        titleLabel.frame = NSRect(x: 2, y: posterH + 8, width: max(0, w - 4), height: 17)
        starsLabel.frame = NSRect(x: 2, y: posterH + 25, width: max(0, w - 4), height: 13)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshVisualState(animated: false)
    }

    // MARK: - Pointer & Click Handling

    override func mouseEntered(with event: NSEvent) {
        guard let coordinator, !coordinator.isLiveScrolling else { return }
        if coordinator.activeHoveredView !== self {
            coordinator.clearHoveredCell(animated: true)
            coordinator.activeHoveredView = self
        }
        setHovered(true, animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        if coordinator?.activeHoveredView === self {
            coordinator?.activeHoveredView = nil
        }
        isPressed = false
        setHovered(false, animated: true)
    }

    override func mouseDown(with event: NSEvent) {
        guard let item, let coordinator else { return }
        if let cv = coordinator.collectionView {
            window?.makeFirstResponder(cv)
        }
        if event.clickCount >= 2 {
            isPressed = false
            refreshVisualState(animated: false)
            coordinator.parent.onEnsureSelectItem(item)
            coordinator.parent.onDoubleClickEdit(item)
        } else {
            isPressed = true
            refreshVisualState(animated: true)
            coordinator.parent.onSelectItem(item)
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
        if let cv = coordinator.collectionView {
            window?.makeFirstResponder(cv)
        }
        coordinator.parent.onEnsureSelectItem(item)

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
            coordinator?.parent.onRequestReplaceCover(item)
        }
        replaceItem.image = NSImage(systemSymbolName: "photo.on.rectangle.angled", accessibilityDescription: nil)
        menu.addItem(replaceItem)

        let localItem = ActionMenuItem(title: lang.tr("选择本地图片…", "Choose Local Image…")) { [weak coordinator] in
            guard let coordinator else { return }
            if let url = CoverManager.shared.chooseLocalImagePanel(lang: lang),
               let saved = CoverManager.shared.saveImageFromFileURL(url) {
                coordinator.parent.onUpdateCoverFileName(item.id, saved)
            }
        }
        localItem.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        menu.addItem(localItem)

        let pasteItem = ActionMenuItem(title: lang.tr("从剪贴板粘贴封面", "Paste Cover from Clipboard")) { [weak self] in
            self?.pasteCoverFromClipboard()
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

        let editItem = ActionMenuItem(title: lang.tr("编辑作品信息…", "Edit Info…")) { [weak coordinator] in
            coordinator?.parent.onDoubleClickEdit(item)
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

    private func pasteCoverFromClipboard() {
        guard let item, let coordinator else { return }
        switch CoverManager.shared.inspectPasteboard() {
        case .image(let img):
            if let saved = CoverManager.shared.saveImage(img) {
                coordinator.parent.onUpdateCoverFileName(item.id, saved)
            }
        case .fileURL(let url):
            if let saved = CoverManager.shared.saveImageFromFileURL(url) {
                coordinator.parent.onUpdateCoverFileName(item.id, saved)
            }
        case .remoteURL(let urlStr):
            let itemID = item.id
            Task { @MainActor [weak coordinator] in
                do {
                    let saved = try await CoverManager.shared.downloadAndSaveImage(from: urlStr)
                    coordinator?.parent.onUpdateCoverFileName(itemID, saved)
                } catch {
                    coordinator?.parent.onShowToast(error.localizedDescription)
                }
            }
        case .empty:
            coordinator.parent.onShowToast(
                language.tr("剪贴板中没有检测到图片或图片链接", "No image or image URL found in clipboard")
            )
        }
    }

    // MARK: - Drag & Drop Cover Replacement

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropOverlay.isHidden = false
        needsLayout = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropOverlay.isHidden = true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        dropOverlay.isHidden = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropOverlay.isHidden = true
        guard let item, let coordinator else { return false }
        let pb = sender.draggingPasteboard

        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let first = urls.first {
            if first.isFileURL {
                if let saved = CoverManager.shared.saveImageFromFileURL(first) {
                    coordinator.parent.onUpdateCoverFileName(item.id, saved)
                    return true
                }
            } else if first.scheme == "http" || first.scheme == "https" {
                let itemID = item.id
                let urlStr = first.absoluteString
                Task { @MainActor [weak coordinator] in
                    do {
                        let saved = try await CoverManager.shared.downloadAndSaveImage(from: urlStr)
                        coordinator?.parent.onUpdateCoverFileName(itemID, saved)
                    } catch {
                        coordinator?.parent.onShowToast(error.localizedDescription)
                    }
                }
                return true
            }
        }

        if let img = NSImage(pasteboard: pb),
           let saved = CoverManager.shared.saveImage(img) {
            coordinator.parent.onUpdateCoverFileName(item.id, saved)
            return true
        }

        if let str = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           let url = URL(string: str),
           (url.scheme == "http" || url.scheme == "https") {
            let itemID = item.id
            Task { @MainActor [weak coordinator] in
                do {
                    let saved = try await CoverManager.shared.downloadAndSaveImage(from: str)
                    coordinator?.parent.onUpdateCoverFileName(itemID, saved)
                } catch {
                    coordinator?.parent.onShowToast(error.localizedDescription)
                }
            }
            return true
        }

        coordinator.parent.onShowToast(CoverError.invalidImageData.message(in: language))
        return false
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
