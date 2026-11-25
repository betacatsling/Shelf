import AppKit
import QuartzCore

// MARK: - Pure CALayer GPU Poster Card View

@MainActor
final class PosterCardInteractiveView: NSView {
    private static let reflowAnimationKey = "drawerReflow"
    private static let artworkFadeKey = "artworkFade"
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
    private static let starStrings: [NSAttributedString] = (0...5).map { count in
        NSAttributedString(
            string: String(repeating: "★", count: count),
            attributes: [
                .font: NSFont.systemFont(ofSize: 9.5, weight: .regular),
                .foregroundColor: ShelfTheme.starGoldNS,
                .kern: 1.3
            ]
        )
    }

    override var isFlipped: Bool { true }

    var posterHitBounds: NSRect {
        let posterH = round(bounds.width * ShelfTheme.posterAspectRatio)
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
        shadowLayer.shadowOpacity = 0.24
        shadowLayer.shadowRadius = 7.5
        shadowLayer.shadowOffset = CGSize(width: 0, height: 4)
        shadowLayer.actions = [
            "shadowOpacity": NSNull(),
            "shadowRadius": NSNull(),
            "shadowOffset": NSNull(),
            "shadowColor": NSNull()
        ]
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
        starsLabel.textColor = ShelfTheme.starGoldNS
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
        badge?.layer?.removeAnimation(forKey: "opacity")
        badge?.layer?.opacity = 0
        badge?.isHidden = true
        dropOverlay?.isHidden = true
    }

    func animateReflow(fromOffset offset: CGPoint) {
        guard let layer else { return }
        let startTransform: CATransform3D
        if layer.animation(forKey: Self.reflowAnimationKey) != nil,
           let current = layer.presentation()?.transform {
            startTransform = CATransform3DTranslate(current, offset.x, offset.y, 0)
        } else {
            startTransform = CATransform3DMakeTranslation(offset.x, offset.y, 0)
        }
        let spring = ShelfMotion.gridReflow(keyPath: "transform")
        spring.fromValue = NSValue(caTransform3D: startTransform)
        spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        layer.add(spring, forKey: Self.reflowAnimationKey)
    }

    func animateReflowEntrance(horizontalOffset: CGFloat) {
        guard let layer else { return }
        let duration: CFTimeInterval = 0.22
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.0
        fade.toValue = 1.0
        fade.duration = duration

        let slide = CABasicAnimation(keyPath: "transform.translation.x")
        slide.isAdditive = true
        slide.fromValue = horizontalOffset
        slide.toValue = 0
        slide.duration = duration

        let group = CAAnimationGroup()
        group.animations = [fade, slide]
        group.duration = duration
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
        layer.add(group, forKey: Self.reflowAnimationKey)
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
                let clampedRating = min(max(item.rating, 0), 5)
                starsLabel.attributedStringValue = Self.starStrings[clampedRating]
                starsLabel.isHidden = clampedRating == 0
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

    private func suspendArtwork() {
        cancelPendingArtwork()
        artworkLayer.removeAnimation(forKey: Self.artworkFadeKey)
        showArtwork(nil, animated: false)
        artworkRequested = false
        placeholderDisplayed = false
    }

    private func cancelPendingArtwork() {
        guard artworkTask != nil else { return }
        artworkTask?.cancel()
        artworkTask = nil
        artworkRequested = false
    }

    private func resumeArtwork() {
        guard let item, !artworkRequested else { return }
        artworkRequested = true
        let manager = CoverManager.shared
        let request = item.artworkRequest(language: language)
        if let artwork = manager.cachedArtwork(for: request) {
            placeholderDisplayed = request.fileName == nil
            showArtwork(artwork, animated: false)
            return
        }
        artworkTask = Task { [weak self] in
            let decoded = await manager.artwork(for: request)
            guard !Task.isCancelled else { return }
            let shouldFade = self?.coordinator?.reduceMotion != true && self?.window != nil
            if let decoded {
                self?.placeholderDisplayed = request.fileName == nil
                self?.showArtwork(decoded, animated: shouldFade)
            } else if request.fileName != nil, let self {
                let image = await manager.artwork(for: item.placeholderRequest(language: self.language))
                guard !Task.isCancelled else { return }
                self.placeholderDisplayed = true
                self.showArtwork(image, animated: shouldFade)
            }
            self?.artworkTask = nil
        }
    }

    private func showArtwork(_ artwork: CoverManager.Artwork?, animated: Bool) {
        if animated && artwork != nil {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.16
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            artworkLayer.add(fade, forKey: Self.artworkFadeKey)
        }
        artworkLayer.contents = artwork?.contents
    }

    func setSelected(_ selected: Bool) {
        guard isCardSelected != selected else { return }
        isCardSelected = selected
        setAccessibilitySelected(selected)
        updateTitleStyle()
        refreshVisualState(animated: window != nil && coordinator?.reduceMotion != true)
    }

    func setHovered(_ hovered: Bool, animated: Bool) {
        guard isHovered != hovered else { return }
        isHovered = hovered
        refreshVisualState(animated: animated)
        needsLayout = true
    }

    private func refreshVisualState(animated: Bool) {
        let moves = coordinator?.reduceMotion != true && coordinator?.isLiveScrolling != true
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        effectiveAppearance.performAsCurrentDrawingAppearance {
            updateStatusBadge(animated: animated && moves)

            let restingBorder = isDark
                ? NSColor.white.withAlphaComponent(0.14).cgColor
                : NSColor.black.withAlphaComponent(0.09).cgColor
            let hoveredBorder = isDark
                ? NSColor.white.withAlphaComponent(0.36).cgColor
                : NSColor.black.withAlphaComponent(0.22).cgColor
            let borderCol: CGColor = isCardSelected
                ? NSColor.controlAccentColor.cgColor
                : (isHovered ? hoveredBorder : restingBorder)
            let borderW: CGFloat = isCardSelected ? 2.2 : (isHovered ? 1.1 : 0.75)

            let scale: CGFloat = moves ? (isPressed ? 0.974 : (isHovered ? 1.028 : 1.0)) : 1
            let liftY: CGFloat = moves && isHovered && !isPressed ? -3 : 0

            let targetShadowOpacity: Float = {
                if isPressed { return isDark ? 0.22 : 0.10 }
                if isHovered { return isDark ? 0.48 : 0.24 }
                if isCardSelected { return isDark ? 0.36 : 0.20 }
                return isDark ? 0.32 : 0.15
            }()
            let targetShadowRadius: CGFloat = isPressed ? 4 : (isHovered ? 15 : (isCardSelected ? 10 : 7.5))
            let targetShadowOffset = CGSize(width: 0, height: isPressed ? 2 : (isHovered ? 8.5 : 4))
            let targetShadowColor: CGColor = isCardSelected && !isHovered
                ? NSColor.controlAccentColor.withAlphaComponent(isDark ? 0.48 : 0.35).cgColor
                : NSColor.black.cgColor

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
                CATransaction.setAnimationDuration(isPressed ? 0.10 : 0.18)
                CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0))
            } else {
                CATransaction.setDisableActions(true)
                posterTransformView.layer?.removeAnimation(forKey: "transform")
                hoverSheenLayer?.removeAnimation(forKey: "opacity")
                borderLayer.removeAllAnimations()
                shadowLayer.removeAllAnimations()
            }
            borderLayer.borderColor = borderCol
            borderLayer.borderWidth = borderW
            if isHovered, hoverSheenLayer == nil {
                let sheen = CAGradientLayer()
                sheen.colors = [NSColor.white.withAlphaComponent(0.16).cgColor,
                                NSColor.white.withAlphaComponent(0.025).cgColor, NSColor.clear.cgColor]
                sheen.startPoint = .zero
                sheen.endPoint = CGPoint(x: 1, y: 1)
                sheen.frame = artworkLayer.bounds
                artworkLayer.addSublayer(sheen)
                hoverSheenLayer = sheen
            }
            hoverSheenLayer?.opacity = isHovered ? 1 : 0

            animateShadowProperty("shadowOpacity", from: shadowLayer.presentation()?.shadowOpacity ?? shadowLayer.shadowOpacity,
                                  to: targetShadowOpacity, animated: animated && moves)
            animateShadowProperty("shadowRadius", from: shadowLayer.presentation()?.shadowRadius ?? shadowLayer.shadowRadius,
                                  to: targetShadowRadius, animated: animated && moves)
            animateShadowProperty("shadowOffset", from: NSValue(size: shadowLayer.presentation()?.shadowOffset ?? shadowLayer.shadowOffset),
                                  to: NSValue(size: targetShadowOffset), animated: animated && moves)
            shadowLayer.shadowOpacity = targetShadowOpacity
            shadowLayer.shadowRadius = targetShadowRadius
            shadowLayer.shadowOffset = targetShadowOffset
            shadowLayer.shadowColor = targetShadowColor

            if let posterLayer = posterTransformView.layer, !CATransform3DEqualToTransform(posterLayer.transform, t) {
                let current = (posterLayer.animation(forKey: "transform") != nil
                               ? posterLayer.presentation()?.transform : nil) ?? posterLayer.transform
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                posterLayer.transform = t
                if animated && moves && !CATransform3DEqualToTransform(current, t) {
                    let spring = isPressed
                        ? ShelfMotion.cardPress(keyPath: "transform")
                        : ShelfMotion.cardHover(keyPath: "transform")
                    spring.fromValue = NSValue(caTransform3D: current)
                    spring.toValue = NSValue(caTransform3D: t)
                    posterLayer.add(spring, forKey: "transform")
                }
                CATransaction.commit()
            }
            layer?.zPosition = isHovered ? 20 : (isCardSelected ? 5 : 0)
            CATransaction.commit()
        }
    }

    private func animateShadowProperty(_ keyPath: String, from: Any, to: Any, animated: Bool) {
        guard animated else {
            shadowLayer.removeAnimation(forKey: keyPath)
            return
        }
        let anim = CABasicAnimation(keyPath: keyPath)
        anim.fromValue = from
        anim.toValue = to
        anim.duration = isPressed ? 0.11 : 0.20
        anim.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
        shadowLayer.add(anim, forKey: keyPath)
    }

    private func updateTitleStyle() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            titleLabel.font = .systemFont(ofSize: 12.5, weight: isCardSelected ? .semibold : .medium)
            titleLabel.textColor = isCardSelected
                ? .controlAccentColor : NSColor.labelColor.withAlphaComponent(0.92)
        }
    }

    private func updateStatusBadge(animated: Bool = false) {
        let visible = item != nil && (showStatusBadge || isHovered)
        guard let item else {
            badge?.isHidden = true
            return
        }
        if !visible {
            guard let badge else { return }
            if animated, let badgeLayer = badge.layer {
                let currentOpacity = badgeLayer.presentation()?.opacity ?? badgeLayer.opacity
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                badgeLayer.opacity = 0
                if currentOpacity > 0.01 {
                    let anim = CABasicAnimation(keyPath: "opacity")
                    anim.fromValue = currentOpacity
                    anim.toValue = 0
                    anim.duration = 0.14
                    anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    badgeLayer.add(anim, forKey: "opacity")
                }
                CATransaction.commit()
            } else {
                badge.layer?.removeAnimation(forKey: "opacity")
                badge.layer?.opacity = 0
                badge.isHidden = true
            }
            return
        }

        let badge: PosterStatusBadge
        if let existing = self.badge {
            badge = existing
        } else {
            badge = PosterStatusBadge()
            badge.layer?.opacity = 0
            if let dropOverlay {
                posterTransformView.addSubview(badge, positioned: .below, relativeTo: dropOverlay)
            } else {
                posterTransformView.addSubview(badge)
            }
            self.badge = badge
        }
        let wasHidden = badge.isHidden || (badge.layer?.opacity ?? 1) < 0.05
        badge.isHidden = false
        let oldWidth = badge.pillWidth
        badge.configure(text: item.category.statusLabel(for: item.status, in: language), status: item.status)
        if wasHidden || oldWidth != badge.pillWidth { needsLayout = true }

        if let badgeLayer = badge.layer {
            let currentOpacity = badgeLayer.presentation()?.opacity ?? badgeLayer.opacity
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            badgeLayer.opacity = 1
            if animated && currentOpacity < 0.99 {
                let anim = CABasicAnimation(keyPath: "opacity")
                anim.fromValue = currentOpacity
                anim.toValue = 1
                anim.duration = 0.16
                anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
                badgeLayer.add(anim, forKey: "opacity")
            } else if !animated {
                badgeLayer.removeAnimation(forKey: "opacity")
            }
            CATransaction.commit()
        }
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        guard w > 10 else { return }
        let posterH = round(w * ShelfTheme.posterAspectRatio)
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

    // MARK: - Pointer, Context Menu & Drag-Drop

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
            coordinator.parent.actions.onDoubleClickEdit(item.id)
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

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let item, let coordinator else { return nil }
        if let grid = coordinator.gridView {
            window?.makeFirstResponder(grid)
        }
        coordinator.select(item.id)
        return PosterCardContextMenu.build(for: item, language: language, coordinator: coordinator)
    }

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
            coordinator.parent.actions.onShowToast(CoverError.invalidImageData.message(in: language))
            return false
        }
        coordinator.parent.actions.onImportCover(item.id, source)
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
            label.frame = NSRect(x: 17, y: round((19 - size.height) * 0.5),
                                 width: ceil(size.width), height: ceil(size.height))
        }
        if self.status != status {
            self.status = status
            dot.backgroundColor = status.nsTintColor.cgColor
        }
    }
}

extension LibraryPoster {
    func artworkRequest(language: AppLanguage) -> CoverManager.Request {
        if let coverFileName, !coverFileName.isEmpty { return .thumbnail(coverFileName) }
        return placeholderRequest(language: language)
    }

    func placeholderRequest(language: AppLanguage) -> CoverManager.Request {
        .placeholder(PosterPlaceholder(title: title, category: category, subtag: subtag,
                                       paletteSeed: paletteSeed, language: language))
    }
}
