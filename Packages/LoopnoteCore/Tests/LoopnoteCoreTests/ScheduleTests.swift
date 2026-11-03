import Foundation
import Testing
@testable import LoopnoteCore

private let istanbul: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Europe/Istanbul")!
    return c
}()

private let berlin: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Europe/Berlin")!
    return c
}()

private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, cal: Calendar = istanbul) -> Date {
    cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}

@Suite("NoteSchedule")
struct NoteScheduleTests {
    @Test func onceFiresOnlyInFuture() {
        let s = NoteSchedule(start: date(2026, 11, 3, 10), rule: .once)
        #expect(s.occurrences(after: date(2026, 11, 3, 9), limit: 5, calendar: istanbul).map(\.date)
                == [date(2026, 11, 3, 10)])
        #expect(s.occurrences(after: date(2026, 11, 3, 10), limit: 5, calendar: istanbul).isEmpty)
    }

    @Test func everyTenMinutes() {
        let s = NoteSchedule(start: date(2026, 11, 3, 9), rule: .everyMinutes(10))
        let o = s.occurrences(after: date(2026, 11, 3, 9, 25), limit: 3, calendar: istanbul)
        #expect(o.map(\.date) == [date(2026, 11, 3, 9, 30), date(2026, 11, 3, 9, 40), date(2026, 11, 3, 9, 50)])
        #expect(o.map(\.index) == [4, 5, 6])
    }

    @Test func everyThreeDaysKeepsWallClockAcrossDST() {
        // Berlin leaves DST on 25 Oct 2026.
        let s = NoteSchedule(start: date(2026, 10, 20, 8, 30, cal: berlin), rule: .everyDays(3))
        let o = s.occurrences(after: date(2026, 10, 21, cal: berlin), limit: 3, calendar: berlin)
        #expect(o.map(\.date) == [date(2026, 10, 23, 8, 30, cal: berlin),
                                  date(2026, 10, 26, 8, 30, cal: berlin),
                                  date(2026, 10, 29, 8, 30, cal: berlin)])
        #expect(o.first?.index == 2)
    }

    @Test func dailyMultipleTimes() {
        let s = NoteSchedule(start: date(2026, 11, 3),
                             rule: .daily(times: [TimeOfDay(hour: 18, minute: 0), TimeOfDay(hour: 8, minute: 30)]))
        let o = s.occurrences(after: date(2026, 11, 3, 12), limit: 3, calendar: istanbul)
        #expect(o.map(\.date) == [date(2026, 11, 3, 18), date(2026, 11, 4, 8, 30), date(2026, 11, 4, 18)])
        #expect(o.map(\.index) == [2, 3, 4])
    }

    @Test func weeklyMondayAndThursday() {
        // 3 Nov 2026 is a Tuesday. Monday = 2, Thursday = 5.
        let s = NoteSchedule(start: date(2026, 11, 3),
                             rule: .weekly(weekdays: [2, 5], times: [TimeOfDay(hour: 9, minute: 0)]))
        let o = s.occurrences(after: date(2026, 11, 3), limit: 3, calendar: istanbul)
        #expect(o.map(\.date) == [date(2026, 11, 5, 9), date(2026, 11, 9, 9), date(2026, 11, 12, 9)])
    }

    @Test func endAfterCount() {
        let s = NoteSchedule(start: date(2026, 11, 3, 9), rule: .everyHours(1), end: .afterCount(3))
        #expect(s.occurrences(after: date(2026, 11, 3, 8), limit: 10, calendar: istanbul).count == 3)
        #expect(s.occurrences(after: date(2026, 11, 3, 10, 30), limit: 10, calendar: istanbul).map(\.date)
                == [date(2026, 11, 3, 11)])
        #expect(!s.hasOccurrence(after: date(2026, 11, 3, 11), calendar: istanbul))
    }

    @Test func endAfterCountDaily() {
        let s = NoteSchedule(start: date(2026, 11, 3),
                             rule: .daily(times: [TimeOfDay(hour: 9, minute: 0)]), end: .afterCount(2))
        #expect(s.occurrences(after: date(2026, 11, 10), limit: 10, calendar: istanbul).isEmpty)
    }

    @Test func endUntil() {
        let s = NoteSchedule(start: date(2026, 11, 3, 9), rule: .everyDays(1), end: .until(date(2026, 11, 5, 9)))
        #expect(s.occurrences(after: date(2026, 11, 3, 8), limit: 10, calendar: istanbul).count == 3)
        let d = NoteSchedule(start: date(2026, 11, 3),
                             rule: .daily(times: [TimeOfDay(hour: 9, minute: 0)]), end: .until(date(2026, 11, 4, 12)))
        #expect(d.occurrences(after: date(2026, 11, 2), limit: 10, calendar: istanbul).count == 2)
    }

    @Test func invalidRulesProduceNothing() {
        #expect(NoteSchedule(start: .now, rule: .interval(minutes: 0)).occurrences(after: .now, limit: 5, calendar: istanbul).isEmpty)
        #expect(NoteSchedule(start: .now, rule: .weekly(weekdays: [], times: [TimeOfDay(hour: 9, minute: 0)]))
            .occurrences(after: .now, limit: 5, calendar: istanbul).isEmpty)
    }
}

@Suite("QuietHours")
struct QuietHoursTests {
    let q = QuietHours.default

    @Test func wrapsMidnight() {
        #expect(q.contains(date(2026, 11, 3, 23, 0), calendar: istanbul))
        #expect(q.contains(date(2026, 11, 4, 3, 0), calendar: istanbul))
        #expect(!q.contains(date(2026, 11, 4, 7, 30), calendar: istanbul))
        #expect(!q.contains(date(2026, 11, 3, 22, 59), calendar: istanbul))
    }

    @Test func windowEnd() {
        #expect(q.windowEnd(after: date(2026, 11, 3, 23, 10), calendar: istanbul) == date(2026, 11, 4, 7, 30))
        #expect(q.windowEnd(after: date(2026, 11, 4, 2, 0), calendar: istanbul) == date(2026, 11, 4, 7, 30))
    }

    @Test func disabled() {
        var off = q
        off.isEnabled = false
        #expect(!off.contains(date(2026, 11, 4, 3, 0), calendar: istanbul))
    }
}

@Suite("AlertPlanner")
struct AlertPlannerTests {
    let planner = AlertPlanner(quietHours: .default, calendar: istanbul, capacity: 60)

    @Test func respectsCapacityAndSetsHorizon() {
        let n = PlannableNote(id: UUID(), schedule: NoteSchedule(start: date(2026, 11, 3, 8), rule: .everyMinutes(10)))
        let plan = planner.plan([n], now: date(2026, 11, 3, 8))
        #expect(plan.alerts.count == 60)
        #expect(plan.horizon == plan.alerts.last?.date)
        #expect(plan.alerts.first?.date == date(2026, 11, 3, 8, 10))
    }

    @Test func quietHourOccurrencesCollapseIntoOneDigest() {
        let a = PlannableNote(id: UUID(), schedule: NoteSchedule(start: date(2026, 11, 3, 22), rule: .everyMinutes(10)))
        let b = PlannableNote(id: UUID(), schedule: NoteSchedule(start: date(2026, 11, 3, 23, 30), rule: .once))
        let plan = AlertPlanner(quietHours: .default, calendar: istanbul, capacity: 200)
            .plan([a, b], now: date(2026, 11, 3, 22, 55))
        let digests = plan.alerts.filter { if case .digest = $0.kind { true } else { false } }
        #expect(digests.count >= 1)
        let first = digests.first!
        #expect(first.date == date(2026, 11, 4, 7, 30))
        if case .digest(let ids) = first.kind { #expect(Set(ids) == [a.id, b.id]) }
        // No single alert during quiet hours.
        #expect(!plan.alerts.contains { alert in
            if case .note = alert.kind { return QuietHours.default.contains(alert.date, calendar: istanbul) }
            return false
        })
    }

    @Test func snoozeSuppressesEarlierOccurrences() {
        let n = PlannableNote(id: UUID(), schedule: NoteSchedule(start: date(2026, 11, 3, 9), rule: .everyMinutes(10)),
                              snoozedUntil: date(2026, 11, 3, 10, 5))
        let plan = planner.plan([n], now: date(2026, 11, 3, 9, 1))
        #expect(plan.alerts.first?.date == date(2026, 11, 3, 10, 5))
        if case .note(_, let occ, _) = plan.alerts.first!.kind { #expect(occ == nil) }
        #expect(plan.alerts[1].date == date(2026, 11, 3, 10, 10))
    }

    @Test func inactiveNotesAreSkipped() {
        let n = PlannableNote(id: UUID(), schedule: NoteSchedule(start: date(2026, 11, 3, 9), rule: .everyHours(1)),
                              isActive: false)
        #expect(planner.plan([n], now: date(2026, 11, 3, 8)).alerts.isEmpty)
    }

    @Test func idsAreUnique() {
        let notes = (0..<5).map { _ in
            PlannableNote(id: UUID(), schedule: NoteSchedule(start: date(2026, 11, 3, 9), rule: .everyMinutes(15)))
        }
        let plan = planner.plan(notes, now: date(2026, 11, 3, 8))
        #expect(Set(plan.alerts.map(\.id)).count == plan.alerts.count)
    }
}

@Suite("SpokenTitle")
struct SpokenTitleTests {
    @Test func firstSentence() {
        #expect(SpokenTitle.fallback(from: "Ruhsat dosyasını kontrol et. Sonra belediyeyi ara.") == "Ruhsat dosyasını kontrol et")
    }

    @Test func truncatesAtWordBoundary() {
        let long = String(repeating: "kelime ", count: 30)
        let t = SpokenTitle.fallback(from: long)
        #expect(t.count <= SpokenTitle.maxLength + 1)
        #expect(t.hasSuffix("…"))
    }

    @Test func empty() {
        #expect(SpokenTitle.fallback(from: "   \n ") == "")
    }
}
