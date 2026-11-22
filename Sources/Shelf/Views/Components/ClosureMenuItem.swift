import AppKit

/// Self-targeted `NSMenuItem` backed by a Swift closure, unifying AppKit menu construction.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(
        title: String,
        systemImage: String? = nil,
        state: NSControl.StateValue = .off,
        isEnabled: Bool = true,
        keyEquivalent: String = "",
        handler: @escaping () -> Void
    ) {
        self.handler = handler
        super.init(title: title, action: #selector(trigger), keyEquivalent: keyEquivalent)
        self.target = self
        self.state = state
        self.isEnabled = isEnabled
        if let systemImage {
            self.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func trigger() {
        handler()
    }
}
