import AppKit
import SwiftUI

/// Reusable search input bar with magnifying glass icon, `SearchCommandTextField`, and clear button.
struct ShelfSearchBar: View {
    let placeholder: String
    @Binding var text: String
    var autoFocus: Bool = false
    var font: NSFont = .systemFont(ofSize: 12.5)
    var iconSize: CGFloat = 12
    var spacing: CGFloat = 7
    var fieldHeight: CGFloat? = nil
    var horizontalPadding: CGFloat = 9
    var verticalPadding: CGFloat = 6
    var cornerRadius: CGFloat = 8
    var fillOpacity: Double = 0.055
    var borderOpacity: Double = 0.09
    var showsChrome: Bool = true
    var onMoveUp: () -> Void = {}
    var onMoveDown: () -> Void = {}
    var onSubmit: (NSEvent.ModifierFlags) -> Void = { _ in }
    var onEscape: () -> Void = {}
    var interceptSubmitWhenEmpty: Bool = true
    var interceptEscapeWhenEmpty: Bool = true
    var trailingHint: String? = nil
    var alwaysShowTrailingHint: Bool = false

    var body: some View {
        let content = HStack(spacing: spacing) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(.secondary)

            SearchCommandTextField(
                placeholder: placeholder,
                text: $text,
                autoFocus: autoFocus,
                font: font,
                onMoveUp: onMoveUp,
                onMoveDown: onMoveDown,
                onSubmit: onSubmit,
                onEscape: onEscape,
                interceptSubmitWhenEmpty: interceptSubmitWhenEmpty,
                interceptEscapeWhenEmpty: interceptEscapeWhenEmpty
            )
            .frame(maxWidth: .infinity)
            .frame(height: fieldHeight)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: min(iconSize, 13)))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }

            if let trailingHint, alwaysShowTrailingHint || text.isEmpty {
                Text(trailingHint)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5.5)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)

        if showsChrome {
            content
                .background(
                    Color.primary.opacity(fillOpacity),
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(borderOpacity), lineWidth: 0.7)
                )
        } else {
            content
        }
    }
}
