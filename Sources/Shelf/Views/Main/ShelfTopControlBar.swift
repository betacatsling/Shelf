import SwiftUI

struct ShelfTopControlBar: View {
    @Environment(LibraryStore.self) private var store
    let counts: [TrackingStatus: Int]

    private var lang: AppLanguage { store.language }
    private var activeCategory: MediaCategory? { store.selectedDestination.activeCategory }

    var body: some View {
        @Bindable var store = store
        HStack(spacing: 12) {
            ViewThatFits(in: .horizontal) {
                segmentedControl(counts: counts, compactLabels: false, selection: $store.statusFilter)
                segmentedControl(counts: counts, compactLabels: true, selection: $store.statusFilter)
                segmentedControl(counts: nil, compactLabels: false, selection: $store.statusFilter)
                segmentedControl(counts: nil, compactLabels: true, selection: $store.statusFilter)
                statusFilterMenu
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            ShelfSortControl(
                sortField: store.sortField,
                sortAscending: store.sortAscending,
                language: lang,
                onSelectField: { store.selectSortField($0) },
                onSetAscending: { store.sortAscending = $0 }
            )
        }
        .padding(.horizontal, ShelfTheme.horizontalPadding)
        .padding(.vertical, 9)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func segmentedControl(
        counts: [TrackingStatus: Int]?,
        compactLabels: Bool,
        selection: Binding<StatusFilterOption>
    ) -> some View {
        ShelfSegmentedControl(
            segments: statusSegments(counts: counts, compactLabels: compactLabels),
            selection: selection,
            verticalPadding: 5.5,
            equalWidthSegments: false
        )
    }

    private var statusFilterMenu: some View {
        let segments = statusSegments(counts: counts, compactLabels: false)
        return Menu {
            ForEach(segments) { segment in
                let title = segment.count.map { "\(segment.title) (\($0))" } ?? segment.title
                Button {
                    store.statusFilter = segment.value
                } label: {
                    if store.statusFilter == segment.value {
                        Label(title, systemImage: "checkmark")
                    } else {
                        Text(title)
                    }
                }
            }
        } label: {
            Label(lang.tr("按状态筛选", "Filter by Status"), systemImage: "line.3.horizontal.decrease")
                .labelStyle(.iconOnly)
        }
        .controlSize(.small)
        .fixedSize()
        .accessibilityValue(segments.first { $0.value == store.statusFilter }?.title ?? "")
        .help(lang.tr("按状态筛选", "Filter by Status"))
    }

    private func statusSegments(
        counts: [TrackingStatus: Int]?,
        compactLabels: Bool
    ) -> [ShelfSegmentedControl<StatusFilterOption>.Segment] {
        var list: [ShelfSegmentedControl<StatusFilterOption>.Segment] = [
            .init(value: .allShelves, title: lang.tr("分栏", "Shelves"))
        ]
        for st in TrackingStatus.filterOrder {
            list.append(
                .init(
                    value: .single(st),
                    title: st.localizedTitle(in: activeCategory, lang: lang, compact: compactLabels),
                    dotColor: st.tintColor,
                    count: counts.map { $0[st, default: 0] }
                )
            )
        }
        return list
    }
}
