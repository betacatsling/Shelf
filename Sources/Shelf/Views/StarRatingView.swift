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
                starIcon(for: index)
            }
        }
        .onHover { inside in
            if !inside { hoveredStar = nil }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityValue("\(rating) / 5")
        .accessibilityAdjustableAction { direction in
            guard interactive else { return }
            switch direction {
            case .increment:
                rating = min(5, rating + 1)
            case .decrement:
                rating = max(0, rating - 1)
            @unknown default:
                break
            }
        }
    }

    @ViewBuilder
    private func starIcon(for index: Int) -> some View {
        let icon = Image(systemName: index <= effectiveRating ? "star.fill" : "star")
            .font(.system(size: starSize, weight: .medium))
            .foregroundStyle(
                index <= effectiveRating
                    ? ShelfTheme.starGold
                    : Color.secondary.opacity(0.38)
            )
            .scaleEffect(!reduceMotion && interactive && hoveredStar == index ? 1.12 : 1.0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hoveredStar == index)

        if interactive {
            icon
                .contentShape(Rectangle())
                .onHover { inside in
                    if inside {
                        hoveredStar = index
                    } else if hoveredStar == index {
                        hoveredStar = nil
                    }
                }
                .onTapGesture {
                    rating = (rating == index) ? 0 : index
                }
        } else {
            icon
        }
    }
}
