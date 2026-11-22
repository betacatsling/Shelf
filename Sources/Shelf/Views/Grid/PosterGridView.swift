import AppKit

@MainActor
final class PosterGridView: NSView {
    weak var coordinator: NativePosterGrid.Coordinator?

    // AppKit's responsive scrolling path can apply several deltas at once when
    // a trackpad gesture hands off to momentum. Keep both phases on the same
    // path as the viewport notifications that mount the poster rows.
    override class var isCompatibleWithResponsiveScrolling: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityRole(.group)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseMoved(with event: NSEvent) {
        coordinator?.refreshHoverAtCurrentMouseLocation(event.locationInWindow)
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
            case PosterGridKeyCode.escape:
                coordinator?.deselect()
                return
            case PosterGridKeyCode.returnKey, PosterGridKeyCode.enterKey:
                coordinator?.editSelectedItem()
                return
            case PosterGridKeyCode.leftArrow, PosterGridKeyCode.rightArrow,
                 PosterGridKeyCode.downArrow, PosterGridKeyCode.upArrow:
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
