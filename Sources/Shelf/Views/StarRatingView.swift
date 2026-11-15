import SwiftUI

struct StarRatingView: View {
    @Binding var rating: Int
    var starSize: CGFloat = 15
    var spacing: CGFloat = 4
    var interactive: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                    .scaleEffect(!reduceMotion && interactive && hoveredStar == index ? 1.12 : 1.0)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hoveredStar == index)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        guard interactive else { return }
                        if inside {
                            hoveredStar = index
                        } else if hoveredStar == index {
                            hoveredStar = nil
                        }
                    }
                    .onTapGesture {
                        guard interactive else { return }
                        rating = (rating == index) ? 0 : index
                    }
            }
        }
        .onHover { inside in
            if !inside { hoveredStar = nil }
        }
    }
}
