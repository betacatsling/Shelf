import AppKit

/// Computes direction-aware artwork prefetch plans around the visible poster viewport.
@MainActor
final class GridArtworkPrefetcher {
    private let ownerID = UUID()
    private var plan: [CoverManager.Request] = []
    private var anchor: NSRect?
    private var movingUp = false

    func updateIfNeeded(
        viewport: NSRect,
        layout: PosterGridLayout,
        language: AppLanguage,
        posterAt: (IndexPath) -> LibraryPoster?
    ) {
        if let anchor, anchor.size == viewport.size {
            let delta = viewport.minY - anchor.minY
            let reversesDirection = (delta < 0) != movingUp
            let distance = reversesDirection ? 32 : max(32, layout.rowStep / 2)
            if abs(delta) < distance { return }
        }
        update(viewport: viewport, layout: layout, language: language, posterAt: posterAt)
    }

    func update(
        viewport: NSRect,
        layout: PosterGridLayout,
        language: AppLanguage,
        posterAt: (IndexPath) -> LibraryPoster?
    ) {
        guard viewport.height > 0 else { return }
        if let anchor, abs(anchor.minY - viewport.minY) > 1 {
            movingUp = viewport.minY < anchor.minY
        }
        let reach = viewport.height * 1.75
        let above = CGRect(x: viewport.minX, y: viewport.minY - reach, width: viewport.width, height: reach)
        let below = CGRect(x: viewport.minX, y: viewport.maxY, width: viewport.width, height: reach)
        let upcoming = layout.itemPaths(in: movingUp ? above : below, reverse: movingUp)
        let behind = layout.itemPaths(in: movingUp ? below : above, reverse: !movingUp)
        let onScreen = layout.itemPaths(in: viewport, reverse: movingUp)

        guard !onScreen.isEmpty || !upcoming.isEmpty || !behind.isEmpty else { return }
        anchor = viewport

        var seen = Set<CoverManager.Request>()
        var next: [CoverManager.Request] = []
        let prioritized = [upcoming.prefix(12), onScreen[...], upcoming.dropFirst(12), behind[...]]
        for paths in prioritized {
            for path in paths {
                if next.count == 36 { break }
                guard let item = posterAt(path) else { continue }
                let request = item.artworkRequest(language: language)
                if seen.insert(request).inserted { next.append(request) }
            }
        }
        if next != plan {
            plan = next
            CoverManager.shared.setPrefetchPlan(next, for: ownerID)
        }
    }

    func stop() {
        anchor = nil
        movingUp = false
        if !plan.isEmpty {
            plan.removeAll(keepingCapacity: true)
            CoverManager.shared.setPrefetchPlan([], for: ownerID)
        }
    }
}
