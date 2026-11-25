import SwiftUI

struct StarRatingView: View {
    @Binding var rating: Int
    var starSize: CGFloat = 15
    var spacing: CGFloat = 4
    var interactive: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveredStar: Int? = nil
    @State private var pulseStar: Int? = nil

    private var effectiveRating: Int {
        hoveredStar ?? rating
    }

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(1...5, id: \.self) { index in
                starIcon(for: index)
            }
        }
        .animation(reduceMotion ? nil : ShelfMotion.micro, value: effectiveRating)
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
        let isFilled = index <= effectiveRating
        let isTarget = interactive && hoveredStar == index
        let isLeadingPreview = interactive && (hoveredStar.map { index < $0 } ?? false)
        let isPulsing = pulseStar == index
        let scale: CGFloat = reduceMotion ? 1.0 : (isPulsing ? 1.24 : (isTarget ? 1.15 : (isLeadingPreview ? 1.04 : 1.0)))

        let icon = Image(systemName: isFilled ? "star.fill" : "star")
            .font(.system(size: starSize, weight: .medium))
            .foregroundStyle(
                isFilled
                    ? ShelfTheme.starGold
                    : Color.secondary.opacity(0.35)
            )
            .shadow(color: isFilled ? ShelfTheme.starGold.opacity(0.28) : .clear, radius: 3, x: 0, y: 1)
            .scaleEffect(scale)
            .animation(reduceMotion ? nil : .spring(duration: 0.22, bounce: 0.25), value: scale)

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
                    let next = (rating == index) ? 0 : index
                    rating = next
                    if next > 0 && !reduceMotion {
                        pulseStar = index
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                            if pulseStar == index { pulseStar = nil }
                        }
                    }
                }
        } else {
            icon
        }
    }
}
