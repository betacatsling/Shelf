import SwiftUI

/// Floating centered-top modal overlay backdrop + card container shared by Quick Find and Tag Picker overlays.
struct ModalOverlayContainer<Content: View>: View {
    let width: CGFloat
    var topPadding: CGFloat = 68
    var cornerRadius: CGFloat = 14
    var backdropOpacity: Double = 0.24
    let onDismiss: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(backdropOpacity)
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)

            content()
                .frame(width: width)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.8)
                )
                .shadow(color: .black.opacity(0.28), radius: 24, y: 12)
                .padding(.top, topPadding)
        }
    }
}
