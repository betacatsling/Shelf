import AppKit
import SwiftUI

/// AppKit-backed single-line input field that captures navigation keys (`↑`, `↓`, `↵`, `Esc`, empty `⌫`)
/// while preserving Chinese IME marked text composition.
struct SearchCommandTextField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    var autoFocus: Bool = false
    var font: NSFont = .systemFont(ofSize: 13)
    var onMoveUp: () -> Void = {}
    var onMoveDown: () -> Void = {}
    var onSubmit: (NSEvent.ModifierFlags) -> Void = { _ in }
    var onEscape: () -> Void = {}
    var onDeleteBackwardWhenEmpty: (() -> Void)? = nil
    var onEndEditing: (() -> Void)? = nil
    var interceptSubmitWhenEmpty: Bool = true
    var interceptEscapeWhenEmpty: Bool = true

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> AutoFocusTextField {
        let field = AutoFocusTextField(string: text)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = font
        field.placeholderString = placeholder
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = context.coordinator
        field.onMoveToWindow = { [weak coordinator = context.coordinator, weak field] in
            guard let coordinator, let field else { return }
            coordinator.focusIfNeeded(field)
        }
        return field
    }

    func updateNSView(_ nsView: AutoFocusTextField, context: Context) {
        context.coordinator.parent = self
        if nsView.placeholderString != placeholder {
            nsView.placeholderString = placeholder
        }
        if nsView.font != font {
            nsView.font = font
        }
        let hasMarked = (nsView.currentEditor() as? NSTextView)?.hasMarkedText() ?? false
        if !hasMarked && nsView.stringValue != text {
            nsView.stringValue = text
        }
        context.coordinator.focusIfNeeded(nsView)
    }

    final class AutoFocusTextField: NSTextField {
        var onMoveToWindow: (() -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                onMoveToWindow?()
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchCommandTextField
        var didAutoFocus = false

        init(parent: SearchCommandTextField) {
            self.parent = parent
        }

        func focusIfNeeded(_ field: NSTextField) {
            guard parent.autoFocus, !didAutoFocus, let window = field.window else { return }
            didAutoFocus = true
            DispatchQueue.main.async { [weak field, weak window] in
                guard let field, let window, window.firstResponder !== field.currentEditor() else { return }
                window.makeFirstResponder(field)
            }
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            if parent.text != field.stringValue {
                parent.text = field.stringValue
            }
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            parent.onEndEditing?()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if textView.hasMarkedText() {
                return false
            }
            if commandSelector == #selector(NSResponder.moveUp(_:)) {
                parent.onMoveUp()
                return true
            }
            if commandSelector == #selector(NSResponder.moveDown(_:)) {
                parent.onMoveDown()
                return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if control.stringValue.trimmed.isEmpty && !parent.interceptSubmitWhenEmpty {
                    return false
                }
                let flags = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
                parent.onSubmit(flags)
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                if control.stringValue.isEmpty && !parent.interceptEscapeWhenEmpty {
                    return false
                }
                parent.onEscape()
                return true
            }
            if commandSelector == #selector(NSResponder.deleteBackward(_:)),
               control.stringValue.isEmpty,
               let onDelete = parent.onDeleteBackwardWhenEmpty {
                onDelete()
                return true
            }
            return false
        }
    }
}
