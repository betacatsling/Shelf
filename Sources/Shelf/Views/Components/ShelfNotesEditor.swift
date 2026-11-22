import SwiftUI

/// Placeholder-backed multi-line notes editor shared between `ItemDetailPanel` and `ItemEditorSheet`.
struct ShelfNotesEditor: View {
    @Binding var text: String
    let placeholder: String
    var fontSize: CGFloat = 12.5
    var lineSpacing: CGFloat = 0
    var minHeight: CGFloat = 96
    var fillOpacity: Double = 0.04
    var borderOpacity: Double = 0.08
    var cornerRadius: CGFloat = 9

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(.system(size: fontSize))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 9)
                    .padding(.leading, 10)
                    .allowsHitTesting(false)
            }

            TextEditor(text: $text)
                .font(.system(size: fontSize))
                .lineSpacing(lineSpacing)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 6)
                .padding(.vertical, 7)
                .frame(minHeight: minHeight)
        }
        .background(
            Color.primary.opacity(fillOpacity),
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(borderOpacity), lineWidth: 0.7)
        )
    }
}
