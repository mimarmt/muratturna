import Foundation

/// A wall-clock time of day (e.g. 08:30), independent of date and time zone.
public struct TimeOfDay: Codable, Hashable, Sendable, Comparable {
    public var hour: Int
    public var minute: Int

    public init(hour: Int, minute: Int) {
        precondition((0...23).contains(hour) && (0...59).contains(minute), "Invalid time of day")
        self.hour = hour
        self.minute = minute
    }

    /// Minutes since midnight.
    public var minutesOfDay: Int { hour * 60 + minute }

    public static func < (lhs: TimeOfDay, rhs: TimeOfDay) -> Bool {
        lhs.minutesOfDay < rhs.minutesOfDay
    }

    /// Returns the date at this time of day on the same calendar day as `date`.
    public func on(_ date: Date, calendar: Calendar) -> Date {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date) ?? date
    }
}

/// How often a note repeats. Intervals are free-form: any number of minutes,
/// so "every 10 minutes", "every 2 hours" and "every 3 days" are all `.interval`.
public enum RepeatRule: Codable, Hashable, Sendable {
    /// Fires exactly once at the note's start date.
    case once
    /// Fires every `minutes` minutes, starting at the note's start date.
    case interval(minutes: Int)
    /// Fires every day at each of the given times.
    case daily(times: [TimeOfDay])
    /// Fires on the given weekdays (1 = Sunday … 7 = Saturday, as in `Calendar`) at each time.
    case weekly(weekdays: Set<Int>, times: [TimeOfDay])

    public static let minimumIntervalMinutes = 1

    public static func everyMinutes(_ m: Int) -> RepeatRule { .interval(minutes: m) }
    public static func everyHours(_ h: Int) -> RepeatRule { .interval(minutes: h * 60) }
    public static func everyDays(_ d: Int) -> RepeatRule { .interval(minutes: d * 1_440) }
    public static func everyWeeks(_ w: Int) -> RepeatRule { .interval(minutes: w * 10_080) }

    public var isValid: Bool {
        switch self {
        case .once:
            return true
        case .interval(let minutes):
            return minutes >= Self.minimumIntervalMinutes
        case .daily(let times):
            return !times.isEmpty
        case .weekly(let weekdays, let times):
            return !weekdays.isEmpty && weekdays.allSatisfy { (1...7).contains($0) } && !times.isEmpty
        }
    }
}

/// When a note stops repeating on its own. Completing a note always stops it.
public enum EndCondition: Codable, Hashable, Sendable {
    case never
    /// No occurrences strictly after this date.
    case until(Date)
    /// Stops after this many occurrences in total.
    case afterCount(Int)
}

/// Do-not-speak window, e.g. 23:00 – 07:30. May wrap past midnight.
public struct QuietHours: Codable, Hashable, Sendable {
    public var start: TimeOfDay
    public var end: TimeOfDay
    public var isEnabled: Bool

    public init(start: TimeOfDay, end: TimeOfDay, isEnabled: Bool = true) {
        self.start = start
        self.end = end
        self.isEnabled = isEnabled
    }

    public static let `default` = QuietHours(start: TimeOfDay(hour: 23, minute: 0),
                                             end: TimeOfDay(hour: 7, minute: 30))

    /// Whether `date` falls inside the quiet window (start inclusive, end exclusive).
    public func contains(_ date: Date, calendar: Calendar) -> Bool {
        guard isEnabled, start != end else { return false }
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        if start < end {
            return m >= start.minutesOfDay && m < end.minutesOfDay
        } else {
            return m >= start.minutesOfDay || m < end.minutesOfDay
        }
    }

    /// The moment the quiet window containing `date` ends. Call only when `contains(date)`.
    public func windowEnd(after date: Date, calendar: Calendar) -> Date {
        let sameDayEnd = end.on(date, calendar: calendar)
        if sameDayEnd > date { return sameDayEnd }
        let nextDay = calendar.date(byAdding: .day, value: 1, to: date) ?? date
        return end.on(nextDay, calendar: calendar)
    }
}
