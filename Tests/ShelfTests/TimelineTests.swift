import Foundation
import Testing
@testable import Shelf

struct TimelineTests {
    private static var utcCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }

    private static func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        utcCalendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    @Test func testMediaItemTimelineCodableRoundTripAndLegacyCompatibility() throws {
        let start = Self.day(2025, 9, 5)
        let finish = Self.day(2025, 9, 22)
        let item = MediaItem(
            title: "空洞骑士：丝之歌",
            titleEN: "Hollow Knight: Silksong",
            category: .game,
            status: .completed,
            startedAt: start,
            finishedAt: finish
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(item)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(MediaItem.self, from: data)
        #expect(decoded.startedAt == start)
        #expect(decoded.finishedAt == finish)
        #expect(decoded.hasTimelineDates)

        // Legacy JSON without startedAt / finishedAt decodes cleanly with nil dates
        var legacyDict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        legacyDict.removeValue(forKey: "startedAt")
        legacyDict.removeValue(forKey: "finishedAt")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyDict)
        let legacyDecoded = try decoder.decode(MediaItem.self, from: legacyData)
        #expect(legacyDecoded.startedAt == nil)
        #expect(legacyDecoded.finishedAt == nil)
        #expect(!legacyDecoded.hasTimelineDates)
    }

    @Test func testEffectiveTimelineSpanSemantics() {
        let now = Self.day(2026, 11, 22)
        let s = Self.day(2026, 10, 1)
        let f = Self.day(2026, 10, 10)

        let completedRange = MediaItem(title: "A", category: .game, status: .completed, startedAt: f, finishedAt: s)
        let span1 = completedRange.effectiveTimelineSpan(now: now)
        #expect(span1?.start == s)
        #expect(span1?.end == f)
        #expect(span1?.isOngoing == false)

        let activeOngoing = MediaItem(title: "B", category: .game, status: .active, startedAt: s, finishedAt: nil)
        let span2 = activeOngoing.effectiveTimelineSpan(now: now)
        #expect(span2?.start == s)
        #expect(span2?.end == now)
        #expect(span2?.isOngoing == true)

        let completedStartOnly = MediaItem(title: "C", category: .game, status: .completed, startedAt: s, finishedAt: nil)
        let span3 = completedStartOnly.effectiveTimelineSpan(now: now)
        #expect(span3?.start == s)
        #expect(span3?.end == s)
        #expect(span3?.isOngoing == false)

        let finishOnly = MediaItem(title: "D", category: .game, status: .unfinished, startedAt: nil, finishedAt: f)
        let span4 = finishOnly.effectiveTimelineSpan(now: now)
        #expect(span4?.start == f)
        #expect(span4?.end == f)
        #expect(span4?.isOngoing == false)

        let undated = MediaItem(title: "E", category: .novel, status: .backlog)
        #expect(undated.effectiveTimelineSpan(now: now) == nil)
    }

    @MainActor
    @Test func testStoreUpdateTimelineDatesNormalizesOrderAndClears() {
        let item = MediaItem(title: "FEZ", category: .game, status: .active)
        let store = LibraryStore(previewItems: [item])
        let early = Self.day(2025, 12, 1)
        let late = Self.day(2025, 12, 20)

        // Reversed dates are automatically normalized so startedAt <= finishedAt
        store.updateTimelineDates(for: item.id, startedAt: late, finishedAt: early)
        #expect(store.item(withID: item.id)?.startedAt == early)
        #expect(store.item(withID: item.id)?.finishedAt == late)

        // Clearing removes both dates
        store.updateTimelineDates(for: item.id, startedAt: nil, finishedAt: nil)
        #expect(store.item(withID: item.id)?.startedAt == nil)
        #expect(store.item(withID: item.id)?.finishedAt == nil)
    }

    @Test func testTimelineLayoutLanePackingAvoidsVisualOverlapAndGroupsCategories() {
        let cal = Self.utcCalendar
        let now = Self.day(2026, 6, 15)

        let gameA = LibraryPoster(
            MediaItem(
                title: "Game A",
                category: .game,
                status: .completed,
                startedAt: Self.day(2026, 5, 1),
                finishedAt: Self.day(2026, 5, 10)
            ),
            language: .en
        )
        let gameB = LibraryPoster(
            MediaItem(
                title: "Game B",
                category: .game,
                status: .completed,
                startedAt: Self.day(2026, 5, 5),
                finishedAt: Self.day(2026, 5, 12)
            ),
            language: .en
        )
        let gameC = LibraryPoster(
            MediaItem(
                title: "Game C",
                category: .game,
                status: .completed,
                startedAt: Self.day(2026, 6, 1),
                finishedAt: Self.day(2026, 6, 3)
            ),
            language: .en
        )
        let novelA = LibraryPoster(
            MediaItem(
                title: "Novel A",
                category: .novel,
                status: .active,
                startedAt: Self.day(2026, 5, 20)
            ),
            language: .en
        )
        let undated = LibraryPoster(
            MediaItem(title: "Backlog Item", category: .game, status: .backlog),
            language: .en
        )

        let model = TimelineLayoutModel.build(
            posters: [gameA, gameB, gameC, novelA, undated],
            groupByCategory: true,
            pointsPerDay: 10.0,
            language: .en,
            now: now,
            calendar: cal
        )

        #expect(model.scheduledCount == 4)
        #expect(model.undatedPosters.map(\.id) == [undated.id])
        #expect(model.groups.count == 2)
        #expect(model.groups[0].category == .game)
        #expect(model.groups[1].category == .novel)

        let gameEntries = Dictionary(uniqueKeysWithValues: model.groups[0].entries.map { ($0.id, $0) })
        #expect(gameEntries[gameA.id]?.lane == 0)
        // Overlaps Game A -> placed in lane 1
        #expect(gameEntries[gameB.id]?.lane == 1)
        // Starts June 1, well after Game A ends visually -> reuses lane 0
        #expect(gameEntries[gameC.id]?.lane == 0)
        #expect(model.groups[0].laneCount == 2)

        // Short bar respects minBarWidth
        #expect((gameEntries[gameC.id]?.width ?? 0) >= TimelineLayoutModel.minBarWidth)

        // Active novel extends to `now`
        let novelEntry = model.groups[1].entries.first
        #expect(novelEntry?.isOngoing == true)
        #expect(novelEntry?.durationDays == 27)
    }

    @Test func testTimelineLayoutRespectsMinBarWidthCollisionAtZoomedOutScale() {
        let cal = Self.utcCalendar
        let now = Self.day(2026, 6, 15)

        // Two 1-day games 5 days apart: at 2 pt/day their date delta is only 10pt,
        // which is much less than minBarWidth (116pt), so they MUST stack into separate lanes.
        let p1 = LibraryPoster(
            MediaItem(title: "Short 1", category: .game, status: .completed, startedAt: Self.day(2026, 5, 1), finishedAt: Self.day(2026, 5, 1)),
            language: .en
        )
        let p2 = LibraryPoster(
            MediaItem(title: "Short 2", category: .game, status: .completed, startedAt: Self.day(2026, 5, 6), finishedAt: Self.day(2026, 5, 6)),
            language: .en
        )

        let model = TimelineLayoutModel.build(
            posters: [p1, p2],
            groupByCategory: false,
            pointsPerDay: 2.0,
            language: .en,
            now: now,
            calendar: cal
        )

        #expect(model.groups.count == 1)
        #expect(model.groups[0].laneCount == 2)
        let lanes = Set(model.groups[0].entries.map(\.lane))
        #expect(lanes == [0, 1])
    }
}
