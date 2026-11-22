import AppKit

@MainActor
final class ShelfSectionHeaderView: NSView {
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
    private var trackedToggleRect: NSRect = .zero
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
        isToggleHovered = false
        onToggle = nil
        addButton.recycle()
        refreshDynamicColors()
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
        if trackedToggleRect != toggleContainer.frame {
            refreshToggleTrackingArea()
        }

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

    func recycle() {
        isHovered = false
        isPressed = false
        onClick = nil
        updateAppearance()
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
        if inside { onClick?() }
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
