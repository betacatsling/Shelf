import AppKit
import QuartzCore

@MainActor
final class ShelfSectionHeaderView: NSView {
    private static let reflowAnimationKey = "sectionReflow"
    private let toggleContainer = NSView()
    private let chevronContainer = NSView()
    private let chevronImageView = NSImageView()
    private let dotLayer = CALayer()
    private let titleLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let dividerLine = NSView()
    private let addButton = HeaderPlusButton()

    private var onToggle: (() -> Void)?
    private var isToggleHovered = false
    private var isCollapsedState: Bool?
    private var toggleTrackingArea: NSTrackingArea?
    private var trackedToggleRect: NSRect = .zero
    private var lastChevronRect: NSRect = .zero
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

    func recycle() {
        cancelReflowAnimation()
        isToggleHovered = false
        isCollapsedState = nil
        onToggle = nil
        addButton.recycle()
        refreshDynamicColors(animated: false)
    }

    func animateReflow(verticalOffset: CGFloat) {
        guard let layer else { return }
        let startTransform: CATransform3D
        if layer.animation(forKey: Self.reflowAnimationKey) != nil,
           let current = layer.presentation()?.transform {
            startTransform = CATransform3DTranslate(current, 0, verticalOffset, 0)
        } else {
            startTransform = CATransform3DMakeTranslation(0, verticalOffset, 0)
        }
        let spring = ShelfMotion.gridReflow(keyPath: "transform")
        spring.fromValue = NSValue(caTransform3D: startTransform)
        spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        layer.add(spring, forKey: Self.reflowAnimationKey)
    }

    func cancelReflowAnimation() {
        layer?.removeAnimation(forKey: Self.reflowAnimationKey)
    }

    private func setupViews() {
        toggleContainer.wantsLayer = true
        toggleContainer.layer?.cornerRadius = 7
        toggleContainer.layer?.cornerCurve = .continuous
        addSubview(toggleContainer)

        chevronContainer.wantsLayer = true
        toggleContainer.addSubview(chevronContainer)

        let cfg = NSImage.SymbolConfiguration(pointSize: 9.5, weight: .bold)
        chevronImageView.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        chevronImageView.imageScaling = .scaleProportionallyDown
        chevronImageView.contentTintColor = .secondaryLabelColor
        chevronContainer.addSubview(chevronImageView)

        dotLayer.cornerRadius = 3.5
        toggleContainer.layer?.addSublayer(dotLayer)

        titleLabel.font = .systemFont(ofSize: 13.5, weight: .semibold)
        titleLabel.textColor = .labelColor.withAlphaComponent(0.92)
        titleLabel.lineBreakMode = .byTruncatingTail
        toggleContainer.addSubview(titleLabel)

        countLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        countLabel.textColor = .tertiaryLabelColor
        countLabel.alignment = .left
        toggleContainer.addSubview(countLabel)

        dividerLine.wantsLayer = true
        addSubview(dividerLine)

        addSubview(addButton)
        refreshDynamicColors(animated: false)
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

        let collapsedChanged = isCollapsedState != nil && isCollapsedState != section.isCollapsed
        isCollapsedState = section.isCollapsed
        updateChevronRotation(collapsed: section.isCollapsed, animated: collapsedChanged && window != nil)

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

    private func updateChevronRotation(collapsed: Bool, animated: Bool) {
        guard let layer = chevronContainer.layer else { return }
        let angle: CGFloat = collapsed ? 0 : (.pi * 0.5)
        let w = chevronContainer.bounds.width
        let h = chevronContainer.bounds.height
        var target = CATransform3DIdentity
        if angle != 0 {
            target = CATransform3DTranslate(target, w * 0.5, h * 0.5, 0)
            target = CATransform3DRotate(target, angle, 0, 0, 1)
            target = CATransform3DTranslate(target, -w * 0.5, -h * 0.5, 0)
        }
        let current = (layer.animation(forKey: "chevronRotate") != nil
                       ? layer.presentation()?.transform : nil) ?? layer.transform
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = target
        if animated && !CATransform3DEqualToTransform(current, target) {
            let spring = ShelfMotion.cardHover(keyPath: "transform")
            spring.fromValue = NSValue(caTransform3D: current)
            spring.toValue = NSValue(caTransform3D: target)
            layer.add(spring, forKey: "chevronRotate")
        } else {
            layer.removeAnimation(forKey: "chevronRotate")
        }
        CATransaction.commit()
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

        let countW = ceil(countLabel.frame.width)
        let toggleW = 8 + 12 + 7 + 7 + 8 + ceil(titleLabel.frame.width) + 7 + countW + 8
        let toggleH: CGFloat = 28

        toggleContainer.frame = NSRect(x: -6, y: round(centerY - toggleH * 0.5), width: toggleW, height: toggleH)
        if trackedToggleRect != toggleContainer.frame {
            refreshToggleTrackingArea()
        }

        let chevronRect = NSRect(x: 8, y: round((toggleH - 12) * 0.5), width: 12, height: 12)
        if lastChevronRect != chevronRect {
            lastChevronRect = chevronRect
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            chevronContainer.layer?.removeAnimation(forKey: "chevronRotate")
            chevronContainer.layer?.transform = CATransform3DIdentity
            chevronContainer.frame = chevronRect
            chevronImageView.frame = chevronContainer.bounds
            CATransaction.commit()
            if let isCollapsedState {
                updateChevronRotation(collapsed: isCollapsedState, animated: false)
            }
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dotLayer.frame = CGRect(x: 27, y: round((toggleH - 7) * 0.5), width: 7, height: 7)
        CATransaction.commit()

        titleLabel.frame = NSRect(
            x: 42,
            y: round((toggleH - titleLabel.frame.height) * 0.5),
            width: ceil(titleLabel.frame.width),
            height: ceil(titleLabel.frame.height)
        )

        countLabel.frame = NSRect(
            x: titleLabel.frame.maxX + 7,
            y: round((toggleH - countLabel.frame.height) * 0.5) + 0.5,
            width: countW,
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
            dividerLine.frame = NSRect(x: lineX, y: round(centerY), width: lineRight - lineX, height: 0.75)
        } else {
            dividerLine.isHidden = true
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        refreshToggleTrackingArea()
    }

    private func refreshToggleTrackingArea() {
        if let toggleTrackingArea {
            removeTrackingArea(toggleTrackingArea)
        }
        trackedToggleRect = toggleContainer.frame
        let area = NSTrackingArea(
            rect: trackedToggleRect,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        toggleTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isToggleHovered = true
        refreshDynamicColors(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        isToggleHovered = false
        refreshDynamicColors(animated: true)
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
        refreshDynamicColors(animated: false)
    }

    private func refreshDynamicColors(animated: Bool) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin()
            if animated {
                CATransaction.setAnimationDuration(0.14)
                CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
            } else {
                CATransaction.setDisableActions(true)
            }
            toggleContainer.layer?.backgroundColor = isToggleHovered
                ? NSColor.labelColor.withAlphaComponent(0.055).cgColor
                : NSColor.clear.cgColor
            dividerLine.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.07).cgColor
            CATransaction.commit()
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
        updateAppearance(animated: false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func recycle() {
        isHovered = false
        isPressed = false
        onClick = nil
        updateAppearance(animated: false)
    }

    override func layout() {
        super.layout()
        iconView.frame = bounds.insetBy(dx: 5, dy: 5)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateAppearance(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressed = false
        updateAppearance(animated: true)
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        updateAppearance(animated: true)
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        updateAppearance(animated: true)
        if inside { onClick?() }
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onClick else { return false }
        onClick()
        return true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance(animated: false)
    }

    private func updateAppearance(animated: Bool) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            iconView.contentTintColor = isHovered ? .labelColor : .tertiaryLabelColor
            CATransaction.begin()
            if animated {
                CATransaction.setAnimationDuration(0.14)
                CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
            } else {
                CATransaction.setDisableActions(true)
            }
            if isPressed {
                layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
            } else if isHovered {
                layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.065).cgColor
            } else {
                layer?.backgroundColor = NSColor.clear.cgColor
            }
            CATransaction.commit()
        }
    }
}
