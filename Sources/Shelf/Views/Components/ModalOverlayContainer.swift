import SwiftUI

/// Floating centered-top frosted modal card container shared by Quick Find and Tag Picker overlays.
struct ModalOverlayContainer<Content: View>: View {
    let width: CGFloat
    var topPadding: CGFloat = 68
    var cornerRadius: CGFloat = 14
    var backdropOpacity: Double = 0.24
    var showsBackdrop: Bool = true
    let onDismiss: () -> Void
    @ViewBuilder let content: () -> Content

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let isDark = colorScheme == .dark
        ZStack(alignment: .top) {
            if showsBackdrop {
                Color.black.opacity(backdropOpacity)
                    .ignoresSafeArea()
                    .onTapGesture(perform: onDismiss)
            } else {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture(perform: onDismiss)
            }

            content()
                .frame(width: width)
                .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(isDark ? 0.22 : 0.65),
                                    Color.primary.opacity(isDark ? 0.12 : 0.12)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.8
                        )
                )
                .shadow(color: .black.opacity(isDark ? 0.45 : 0.18), radius: 28, x: 0, y: 14)
                .padding(.top, topPadding)
        }
    }
}
