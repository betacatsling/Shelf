import AppKit

/// Posters have uniform dimensions. Compute row geometry once and create AppKit
/// frames only for the rows near the viewport.
@MainActor
final class PosterGridLayout {
    private struct Section: Equatable {
        let hasHeader: Bool
        let collapsed: Bool
        let itemCount: Int
    }

    private struct Geometry {
        let header: CGRect?
        let firstRowY: CGFloat
        let itemCount: Int
        let rows: Int
    }

    private var sections: [Section] = []
    private var geometry: [Geometry] = []
    private(set) var contentHeight: CGFloat = 0
    private var preparedWidth: CGFloat?
    private var preparedWidthBasis: CGFloat?
    private var scale = 1.0
    private var columns = 1
    private var cardWidth: CGFloat = 0
    private var cellHeight: CGFloat = 0
    private var columnStep: CGFloat = 0
    private(set) var rowStep: CGFloat = 0
    private let padding: CGFloat = 24

    @discardableResult
    func update(sections: [ShelfSectionModel], scale: Double, width: CGFloat,
                posterWidthBasis: CGFloat? = nil) -> Bool {
        let metrics = sections.map {
            Section(hasHeader: $0.status != nil, collapsed: $0.isCollapsed, itemCount: $0.visibleCount)
        }
        guard self.sections != metrics || self.scale != scale || preparedWidth != width
                || preparedWidthBasis != posterWidthBasis else { return false }
        self.sections = metrics
        self.scale = scale
        preparedWidth = width
        preparedWidthBasis = posterWidthBasis

        let minWidth = round(148 * scale)
        let maxWidth = round(186 * scale)
        let spacing = round(20 * max(0.85, scale * 0.95))
        let rowSpacing = round(24 * max(0.88, scale * 0.95))
        // Opening the drawer changes how many cards fit, while their size stays fixed.
        let fullWidth = max(width, posterWidthBasis ?? width)
        let fullAvailable = max(minWidth, max(240, fullWidth) - padding * 2)
        let fullColumns = max(1, Int((fullAvailable + spacing) / (minWidth + spacing)))
        let fittedWidth = floor((fullAvailable - CGFloat(fullColumns - 1) * spacing) / CGFloat(fullColumns))
        let available = max(minWidth, max(240, width) - padding * 2)
        cardWidth = min(available, fullColumns == 1 ? maxWidth : maxWidth + 24, fittedWidth)
        columns = max(1, Int((available + spacing) / (cardWidth + spacing)))
        cellHeight = round(cardWidth * 1.5) + 40
        columnStep = cardWidth + spacing
        rowStep = cellHeight + rowSpacing

        var y: CGFloat = 0
        geometry = metrics.enumerated().map { index, section in
            let first = index == 0
            let last = index == metrics.count - 1
            let header: CGRect?
            if section.hasHeader {
                let height: CGFloat = first ? 44 : 40
                header = CGRect(x: padding, y: y, width: max(0, width - padding * 2), height: height)
                y += height
                y += section.collapsed ? 0 : 12
            } else {
                header = nil
                y += first ? 18 : 10
            }
            let rows = (section.itemCount + columns - 1) / columns
            let result = Geometry(header: header, firstRowY: y, itemCount: section.itemCount, rows: rows)
            if rows > 0 { y += CGFloat(rows - 1) * rowStep + cellHeight }
            y += last ? 34 : (section.collapsed ? 14 : 26)
            return result
        }
        contentHeight = y
        return true
    }

    func headers(in rect: CGRect) -> [(Int, CGRect)] {
        geometry.enumerated().compactMap { index, section in
            guard let header = section.header, header.intersects(rect) else { return nil }
            return (index, header)
        }
    }

    func itemPaths(in rect: CGRect, reverse: Bool) -> [IndexPath] {
        var paths: [IndexPath] = []
        visitItems(in: rect) { path, _ in paths.append(path) }
        if reverse { paths.reverse() }
        return paths
    }

    func itemPath(at point: CGPoint) -> IndexPath? {
        guard point.x >= padding, columnStep > 0 else { return nil }
        let column = Int((point.x - padding) / columnStep)
        guard column < columns else { return nil }
        for (index, section) in geometry.enumerated() where section.rows > 0 && point.y >= section.firstRowY {
            let row = Int((point.y - section.firstRowY) / rowStep)
            guard row < section.rows else { continue }
            let item = row * columns + column
            guard item < section.itemCount, frame(row: row, column: column, in: section).contains(point)
            else { return nil }
            return IndexPath(item: item, section: index)
        }
        return nil
    }

    func visitItems(in rect: CGRect, _ visit: (IndexPath, CGRect) -> Void) {
        for (index, section) in geometry.enumerated() {
            guard let rows = visibleRows(in: section, rect: rect) else { continue }
            let startColumn = max(0, Int(floor((rect.minX - padding) / columnStep)))
            let endColumn = min(columns - 1, Int(floor((rect.maxX - padding) / columnStep)))
            guard startColumn <= endColumn else { continue }
            for row in rows {
                for column in startColumn...endColumn {
                    let item = row * columns + column
                    guard item < section.itemCount else { break }
                    let frame = frame(row: row, column: column, in: section)
                    if frame.intersects(rect) {
                        visit(IndexPath(item: item, section: index), frame)
                    }
                }
            }
        }
    }

    func itemFrame(at indexPath: IndexPath) -> CGRect? {
        guard geometry.indices.contains(indexPath.section) else { return nil }
        let section = geometry[indexPath.section]
        guard (0..<section.itemCount).contains(indexPath.item) else { return nil }
        return frame(row: indexPath.item / columns, column: indexPath.item % columns, in: section)
    }

    func itemInAdjacentRow(from path: IndexPath, direction: Int) -> IndexPath? {
        guard geometry.indices.contains(path.section) else { return nil }
        var index = path.section
        var row = path.item / columns + direction
        let column = path.item % columns
        if !(0..<geometry[index].rows).contains(row) {
            repeat {
                index += direction
                guard geometry.indices.contains(index) else { return nil }
            } while geometry[index].rows == 0
            row = direction > 0 ? 0 : geometry[index].rows - 1
        }
        let item = min(row * columns + column, geometry[index].itemCount - 1)
        return IndexPath(item: item, section: index)
    }

    private func visibleRows(in section: Geometry, rect: CGRect) -> ClosedRange<Int>? {
        guard section.rows > 0, rect.maxY > section.firstRowY,
              rect.minY < section.firstRowY + CGFloat(section.rows - 1) * rowStep + cellHeight else { return nil }
        let first = max(0, Int(floor((rect.minY - section.firstRowY) / rowStep)))
        let last = min(section.rows - 1, Int(floor((rect.maxY - section.firstRowY) / rowStep)))
        return first...last
    }

    private func frame(row: Int, column: Int, in section: Geometry) -> CGRect {
        CGRect(x: padding + CGFloat(column) * columnStep,
               y: section.firstRowY + CGFloat(row) * rowStep, width: cardWidth, height: cellHeight)
    }

}
