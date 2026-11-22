import Foundation

struct TimelineEntry: Identifiable, Equatable, Sendable {
    let poster: LibraryPoster
    let startDay: Date
    let endDay: Date
    let isOngoing: Bool
    let durationDays: Int
    let lane: Int
    let x: CGFloat
    let width: CGFloat
    let actualWidth: CGFloat

    var id: UUID { poster.id }
}

struct TimelineGroup: Identifiable, Equatable, Sendable {
    let id: String
    let category: MediaCategory?
    let title: String
    let laneCount: Int
    let entries: [TimelineEntry]
}

struct TimelineMonthTick: Identifiable, Equatable, Sendable {
    let id: String
    let date: Date
    let year: Int
    let month: Int
    let isYearStart: Bool
    let x: CGFloat
    let width: CGFloat
    let dayCount: Int
}

struct TimelineLayoutModel: Equatable, Sendable {
    static let minBarWidth: CGFloat = 116
    static let barHorizontalGap: CGFloat = 10
    static let leadingCanvasPadding: CGFloat = 24

    let rangeStart: Date
    let rangeEnd: Date
    let totalDays: Int
    let totalWidth: CGFloat
    let pointsPerDay: CGFloat
    let todayDay: Date
    let todayX: CGFloat
    let todayMonthID: String
    let latestActivityMonthID: String
    let monthTicks: [TimelineMonthTick]
    let groups: [TimelineGroup]
    let scheduledCount: Int
    let undatedPosters: [LibraryPoster]

    static var gregorianCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        return cal
    }

    static func monthID(year: Int, month: Int) -> String {
        String(format: "%04d-%02d", year, month)
    }

    static func build(
        posters: [LibraryPoster],
        groupByCategory: Bool,
        pointsPerDay: CGFloat,
        language: AppLanguage,
        now: Date = Date(),
        calendar: Calendar = gregorianCalendar
    ) -> TimelineLayoutModel {
        let safePPD = max(pointsPerDay, 0.5)
        let todayDay = calendar.startOfDay(for: now)

        struct RawSpan {
            let poster: LibraryPoster
            let startDay: Date
            let endDay: Date
            let isOngoing: Bool
            let durationDays: Int
        }

        var rawSpans: [RawSpan] = []
        var undated: [LibraryPoster] = []
        rawSpans.reserveCapacity(posters.count)

        for poster in posters {
            if let span = poster.effectiveTimelineSpan(now: now) {
                let startDay = calendar.startOfDay(for: span.start)
                let endDay = max(startDay, calendar.startOfDay(for: span.end))
                let delta = calendar.dateComponents([.day], from: startDay, to: endDay).day ?? 0
                rawSpans.append(
                    RawSpan(
                        poster: poster,
                        startDay: startDay,
                        endDay: endDay,
                        isOngoing: span.isOngoing,
                        durationDays: max(1, delta + 1)
                    )
                )
            } else {
                undated.append(poster)
            }
        }

        let earliestDataDay = rawSpans.map(\.startDay).min() ?? todayDay
        let latestDataDay = rawSpans.map(\.endDay).max() ?? todayDay

        let anchorStart = min(earliestDataDay, calendar.date(byAdding: .month, value: -2, to: todayDay) ?? todayDay)
        let anchorEnd = max(latestDataDay, calendar.date(byAdding: .month, value: 1, to: todayDay) ?? todayDay)

        let paddedStartAnchor = calendar.date(byAdding: .month, value: -1, to: anchorStart) ?? anchorStart
        let rangeStart = startOfMonth(for: paddedStartAnchor, calendar: calendar)

        let paddedEndAnchor = calendar.date(byAdding: .month, value: 2, to: anchorEnd) ?? anchorEnd
        let rangeEnd = startOfMonth(for: paddedEndAnchor, calendar: calendar)

        let totalDays = max(30, calendar.dateComponents([.day], from: rangeStart, to: rangeEnd).day ?? 30)

        func xForDay(_ day: Date) -> CGFloat {
            let offset = calendar.dateComponents([.day], from: rangeStart, to: day).day ?? 0
            return leadingCanvasPadding + CGFloat(offset) * safePPD
        }

        var monthTicks: [TimelineMonthTick] = []
        var cursor = rangeStart
        while cursor < rangeEnd {
            let nextMonth = calendar.date(byAdding: .month, value: 1, to: cursor) ?? rangeEnd
            let comps = calendar.dateComponents([.year, .month], from: cursor)
            let year = comps.year ?? 2000
            let month = comps.month ?? 1
            let dayCount = max(1, calendar.dateComponents([.day], from: cursor, to: nextMonth).day ?? 30)
            monthTicks.append(
                TimelineMonthTick(
                    id: monthID(year: year, month: month),
                    date: cursor,
                    year: year,
                    month: month,
                    isYearStart: month == 1,
                    x: xForDay(cursor),
                    width: CGFloat(dayCount) * safePPD,
                    dayCount: dayCount
                )
            )
            cursor = nextMonth
        }

        let groupedRaw: [(id: String, category: MediaCategory?, title: String, items: [RawSpan])]
        if groupByCategory {
            groupedRaw = MediaCategory.allCases.compactMap { category in
                let bucket = rawSpans.filter { $0.poster.category == category }
                guard !bucket.isEmpty else { return nil }
                return (category.rawValue, category, category.title(in: language), bucket)
            }
        } else if !rawSpans.isEmpty {
            let category = rawSpans.first?.poster.category
            let title = category?.title(in: language) ?? language.tr("时间线", "Timeline")
            groupedRaw = [("all", category, title, rawSpans)]
        } else {
            groupedRaw = []
        }

        var maxOccupiedX = leadingCanvasPadding + CGFloat(totalDays) * safePPD + leadingCanvasPadding
        var groups: [TimelineGroup] = []
        groups.reserveCapacity(groupedRaw.count)

        for bucket in groupedRaw {
            let sorted = bucket.items.sorted { lhs, rhs in
                if lhs.startDay != rhs.startDay { return lhs.startDay < rhs.startDay }
                if lhs.durationDays != rhs.durationDays { return lhs.durationDays > rhs.durationDays }
                return lhs.poster.title.localizedStandardCompare(rhs.poster.title) == .orderedAscending
            }

            var laneEndX: [CGFloat] = []
            var entries: [TimelineEntry] = []
            entries.reserveCapacity(sorted.count)

            for span in sorted {
                let x = xForDay(span.startDay)
                let actualWidth = max(4, CGFloat(span.durationDays) * safePPD)
                let width = max(actualWidth, minBarWidth)

                let lane: Int
                if let existing = laneEndX.firstIndex(where: { $0 <= x }) {
                    lane = existing
                    laneEndX[existing] = x + width + barHorizontalGap
                } else {
                    lane = laneEndX.count
                    laneEndX.append(x + width + barHorizontalGap)
                }

                maxOccupiedX = max(maxOccupiedX, x + width + leadingCanvasPadding)
                entries.append(
                    TimelineEntry(
                        poster: span.poster,
                        startDay: span.startDay,
                        endDay: span.endDay,
                        isOngoing: span.isOngoing,
                        durationDays: span.durationDays,
                        lane: lane,
                        x: x,
                        width: width,
                        actualWidth: actualWidth
                    )
                )
            }

            groups.append(
                TimelineGroup(
                    id: bucket.id,
                    category: bucket.category,
                    title: bucket.title,
                    laneCount: max(1, laneEndX.count),
                    entries: entries
                )
            )
        }

        let todayComps = calendar.dateComponents([.year, .month], from: todayDay)
        let todayMonthID = monthID(year: todayComps.year ?? 2000, month: todayComps.month ?? 1)
        let latestAnchor = rawSpans.isEmpty ? todayDay : latestDataDay
        let latestComps = calendar.dateComponents([.year, .month], from: latestAnchor)
        let latestActivityMonthID = monthID(year: latestComps.year ?? 2000, month: latestComps.month ?? 1)

        return TimelineLayoutModel(
            rangeStart: rangeStart,
            rangeEnd: rangeEnd,
            totalDays: totalDays,
            totalWidth: maxOccupiedX,
            pointsPerDay: safePPD,
            todayDay: todayDay,
            todayX: xForDay(todayDay),
            todayMonthID: todayMonthID,
            latestActivityMonthID: latestActivityMonthID,
            monthTicks: monthTicks,
            groups: groups,
            scheduledCount: rawSpans.count,
            undatedPosters: undated
        )
    }

    private static func startOfMonth(for date: Date, calendar: Calendar) -> Date {
        let comps = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: comps) ?? calendar.startOfDay(for: date)
    }
}
