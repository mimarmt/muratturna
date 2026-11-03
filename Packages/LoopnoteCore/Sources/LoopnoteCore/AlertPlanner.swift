import Foundation

/// The planner's view of a note. Built from the persisted model by the app.
public struct PlannableNote: Hashable, Sendable {
    public var id: UUID
    public var schedule: NoteSchedule
    /// False when the note is completed/archived or its project is muted.
    public var isActive: Bool
    /// When set and in the future, regular occurrences before it are suppressed
    /// and the note fires once at this moment instead.
    public var snoozedUntil: Date?
    /// Critical notes are delivered as alarms (AlarmKit) instead of notifications.
    public var isCritical: Bool

    public init(id: UUID, schedule: NoteSchedule, isActive: Bool = true,
                snoozedUntil: Date? = nil, isCritical: Bool = false) {
        self.id = id
        self.schedule = schedule
        self.isActive = isActive
        self.snoozedUntil = snoozedUntil
        self.isCritical = isCritical
    }
}

/// A single system alert the app should schedule.
public struct PlannedAlert: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable {
        /// One note speaks. `occurrence` is nil for a snooze firing.
        case note(id: UUID, occurrence: Int?, critical: Bool)
        /// Notes that fell into quiet hours, read together when the window ends.
        case digest(ids: [UUID])
    }

    public var date: Date
    public var kind: Kind

    /// Stable identifier, safe to use as a notification request identifier.
    public var id: String {
        let t = Int(date.timeIntervalSince1970)
        switch kind {
        case .note(let id, let occ, _):
            return "note.\(id.uuidString).\(occ.map(String.init) ?? "snooze").\(t)"
        case .digest:
            return "digest.\(t)"
        }
    }
}

public struct AlertPlan: Sendable {
    public var alerts: [PlannedAlert]
    /// The app must replan no later than this moment (the last planned alert), or nil if nothing is pending.
    public var horizon: Date?
}

/// Turns notes into a bounded list of concrete alerts.
///
/// iOS keeps at most 64 pending local notifications per app, so the planner
/// emits the soonest `capacity` alerts across all notes and reports a horizon.
/// The app replans on launch, on every change, when an alert is delivered,
/// and from a background refresh task scheduled before the horizon.
public struct AlertPlanner: Sendable {
    public static let systemNotificationLimit = 64

    public var quietHours: QuietHours
    public var calendar: Calendar
    public var capacity: Int

    public init(quietHours: QuietHours, calendar: Calendar = .current,
                capacity: Int = AlertPlanner.systemNotificationLimit - 4) {
        self.quietHours = quietHours
        self.calendar = calendar
        self.capacity = max(1, capacity)
    }

    public func plan(_ notes: [PlannableNote], now: Date) -> AlertPlan {
        var singles: [PlannedAlert] = []
        var digests: [Date: [UUID]] = [:]

        func place(_ date: Date, _ note: PlannableNote, occurrence: Int?) {
            if quietHours.contains(date, calendar: calendar) {
                let wake = quietHours.windowEnd(after: date, calendar: calendar)
                if !(digests[wake]?.contains(note.id) ?? false) {
                    digests[wake, default: []].append(note.id)
                }
            } else {
                singles.append(PlannedAlert(date: date,
                                            kind: .note(id: note.id, occurrence: occurrence,
                                                        critical: note.isCritical)))
            }
        }

        for note in notes where note.isActive {
            var from = now
            if let snooze = note.snoozedUntil, snooze > now {
                place(snooze, note, occurrence: nil)
                from = snooze
            }
            // A note that repeats every few minutes can produce many quiet-hour
            // occurrences; they collapse into one digest entry, so fetch generously.
            let occ = note.schedule.occurrences(after: from, limit: capacity * 4, calendar: calendar)
            for o in occ { place(o.date, note, occurrence: o.index) }
        }

        var all = singles
        for (date, ids) in digests {
            all.append(PlannedAlert(date: date, kind: .digest(ids: ids)))
        }
        all.sort { a, b in
            if a.date != b.date { return a.date < b.date }
            return a.id < b.id
        }
        let chosen = Array(all.prefix(capacity))
        return AlertPlan(alerts: chosen, horizon: chosen.last?.date)
    }
}
