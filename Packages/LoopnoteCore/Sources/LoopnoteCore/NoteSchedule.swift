import Foundation

/// One concrete firing of a note's schedule.
public struct Occurrence: Hashable, Sendable {
    public var date: Date
    /// 1-based position in the note's sequence of occurrences.
    public var index: Int
}

/// The complete timing definition of a note.
public struct NoteSchedule: Codable, Hashable, Sendable {
    public var start: Date
    public var rule: RepeatRule
    public var end: EndCondition

    public init(start: Date, rule: RepeatRule, end: EndCondition = .never) {
        self.start = start
        self.rule = rule
        self.end = end
    }

    /// Occurrences strictly after `after`, in ascending order, at most `limit`.
    public func occurrences(after: Date, limit: Int, calendar: Calendar) -> [Occurrence] {
        guard limit > 0, rule.isValid else { return [] }
        var result: [Occurrence] = []
        result.reserveCapacity(min(limit, 128))

        func accept(_ o: Occurrence) -> Bool {
            switch end {
            case .never: break
            case .until(let last): if o.date > last { return false }
            case .afterCount(let n): if o.index > n { return false }
            }
            result.append(o)
            return result.count < limit
        }

        switch rule {
        case .once:
            if start > after { _ = accept(Occurrence(date: start, index: 1)) }

        case .interval(let minutes):
            if minutes % 1_440 == 0 {
                // Whole days: step by calendar days so the wall-clock time survives DST changes.
                let days = minutes / 1_440
                var n = 0
                if after >= start {
                    let elapsed = calendar.dateComponents([.day], from: start, to: after).day ?? 0
                    n = max(0, elapsed / days - 1)
                }
                while true {
                    guard let d = calendar.date(byAdding: .day, value: n * days, to: start) else { break }
                    n += 1
                    if d <= after { continue }
                    if !accept(Occurrence(date: d, index: n)) { break }
                }
            } else {
                let step = TimeInterval(minutes * 60)
                var n = 0
                if after >= start {
                    n = Int(floor(after.timeIntervalSince(start) / step)) + 1
                }
                while true {
                    let d = start.addingTimeInterval(Double(n) * step)
                    n += 1
                    if d <= after { continue }
                    if !accept(Occurrence(date: d, index: n)) { break }
                }
            }

        case .daily(let times), .weekly(_, let times):
            let sortedTimes = Array(Set(times)).sorted()
            var weekdays: Set<Int>? = nil
            if case .weekly(let w, _) = rule { weekdays = w }
            var day = calendar.startOfDay(for: start)
            var index = 0
            // Guard against runaway loops (e.g. a weekly rule on no valid weekday).
            var safety = 0
            outer: while safety < 200_000 {
                safety += 1
                let wd = calendar.component(.weekday, from: day)
                if weekdays == nil || weekdays!.contains(wd) {
                    for t in sortedTimes {
                        let d = t.on(day, calendar: calendar)
                        if d < start { continue }
                        index += 1
                        if d <= after {
                            if case .afterCount(let n) = end, index >= n { break outer }
                            continue
                        }
                        if !accept(Occurrence(date: d, index: index)) { break outer }
                    }
                }
                if case .until(let last) = end, day > last { break }
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        }
        return result
    }

    /// Whether the schedule has at least one occurrence after `date`.
    public func hasOccurrence(after date: Date, calendar: Calendar) -> Bool {
        !occurrences(after: date, limit: 1, calendar: calendar).isEmpty
    }
}
