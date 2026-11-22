import SwiftUI

/// Consistent sheet footer with optional inline warning/error message, Cancel button, and Primary action button.
struct SheetFooterBar: View {
    let errorMessage: String?
    let cancelTitle: String
    let confirmTitle: String
    var confirmDisabled: Bool = false
    var horizontalPadding: CGFloat = 20
    var verticalPadding: CGFloat = 12
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let errorMessage, !errorMessage.isEmpty {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            Button(cancelTitle, action: onCancel)
                .buttonStyle(ShelfButtonStyle(variant: .secondary, horizontalPadding: 14, verticalPadding: 6))
                .keyboardShortcut(.cancelAction)

            Button(confirmTitle, action: onConfirm)
                .buttonStyle(ShelfButtonStyle(variant: .primary, horizontalPadding: 16, verticalPadding: 6))
                .disabled(confirmDisabled)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
    }
}
