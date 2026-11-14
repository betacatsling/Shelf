import SwiftUI

struct StarRatingView: View {
    @Binding var rating: Int
    var starSize: CGFloat = 15
    var spacing: CGFloat = 4
    var interactive: Bool = true

    @State private var hoveredStar: Int? = nil

    private var effectiveRating: Int {
        hoveredStar ?? rating
    }

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(1...5, id: \.self) { index in
                Image(systemName: index <= effectiveRating ? "star.fill" : "star")
                    .font(.system(size: starSize, weight: .medium))
                    .foregroundStyle(
                        index <= effectiveRating
                            ? Color(red: 0.98, green: 0.76, blue: 0.20)
                            : Color.secondary.opacity(0.38)
                    )
                    .scaleEffect(interactive && hoveredStar == index ? 1.18 : 1.0)
                    .animation(.spring(response: 0.22, dampingFraction: 0.7), value: hoveredStar)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        guard interactive else { return }
                        hoveredStar = inside ? index : nil
                    }
                    .onTapGesture {
                        guard interactive else { return }
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                            rating = (rating == index) ? 0 : index
                        }
                    }
            }
        }
        .onHover { inside in
            if !inside { hoveredStar = nil }
        }
    }
}
