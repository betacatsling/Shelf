import SwiftUI

struct ShelfFlowLayout: Layout {
    var alignment: HorizontalAlignment = .leading
    var horizontalSpacing: CGFloat = 6
    var verticalSpacing: CGFloat = 6

    private struct Item {
        let index: Int
        let size: CGSize
        let x: CGFloat
    }

    private struct Row {
        var items: [Item] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let (rows, totalHeight) = arrange(subviews: subviews, maxWidth: maxWidth)
        let contentWidth = rows.map(\.width).max() ?? 0
        let width = maxWidth.isFinite ? max(maxWidth, contentWidth) : contentWidth
        return CGSize(width: width, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (rows, _) = arrange(subviews: subviews, maxWidth: bounds.width)
        var y = bounds.minY
        for row in rows {
            let startX: CGFloat
            switch alignment {
            case .center:
                startX = bounds.minX + max(0, (bounds.width - row.width) * 0.5)
            case .trailing:
                startX = bounds.maxX - row.width
            default:
                startX = bounds.minX
            }

            for item in row.items {
                let x = startX + item.x
                let itemY = y + (row.height - item.size.height) * 0.5
                subviews[item.index].place(
                    at: CGPoint(x: x, y: itemY),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: item.size.width, height: item.size.height)
                )
            }
            y += row.height + verticalSpacing
        }
    }

    private func arrange(subviews: Subviews, maxWidth: CGFloat) -> ([Row], CGFloat) {
        let limit = maxWidth > 0 ? maxWidth : .infinity
        let childProposal = ProposedViewSize(width: limit.isFinite ? limit : nil, height: nil)

        var rows: [Row] = []
        var current = Row()

        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(childProposal)
            let nextX = current.items.isEmpty ? 0 : current.width + horizontalSpacing
            if !current.items.isEmpty && nextX + size.width > limit {
                rows.append(current)
                current = Row(
                    items: [Item(index: index, size: size, x: 0)],
                    width: size.width,
                    height: size.height
                )
            } else {
                current.items.append(Item(index: index, size: size, x: nextX))
                current.width = nextX + size.width
                current.height = max(current.height, size.height)
            }
        }

        if !current.items.isEmpty {
            rows.append(current)
        }

        let totalHeight = rows.enumerated().reduce(CGFloat(0)) { partial, entry in
            partial + entry.element.height + (entry.offset > 0 ? verticalSpacing : 0)
        }
        return (rows, totalHeight)
    }
}
