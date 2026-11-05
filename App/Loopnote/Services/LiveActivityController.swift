import ActivityKit
import Foundation

/// Starts and updates Loopnote's Live Activities (meeting recording, next note).
/// Not actor-isolated: callers fire-and-forget with Sendable values only.
enum LiveActivityController {
    typealias Attributes = LoopnoteActivityAttributes

    private static func activities(_ kind: Attributes.Kind) -> [Activity<Attributes>] {
        Activity<Attributes>.activities.filter { $0.attributes.kind == kind }
    }

    /// UI smoke tests skip Live Activities: a ticking countdown in the Dynamic Island keeps
    /// SpringBoard busy, and the test runner waits for it to settle before every step.
    private static var enabled: Bool {
        !ProcessInfo.processInfo.arguments.contains("-uitest")
            && ActivityAuthorizationInfo().areActivitiesEnabled
    }

    // MARK: Fire-and-forget entry points

    static func startMeeting(at start: Date) {
        Task.detached { await requestMeeting(start: start) }
    }

    /// `start` is shifted on resume so the timer keeps showing elapsed recording time.
    static func updateMeeting(start: Date, paused: Bool) {
        Task.detached { await refreshMeeting(start: start, paused: paused) }
    }

    static func endMeeting() {
        Task.detached { await end(.meeting) }
    }

    /// Shows the next note on the Lock Screen when it speaks within the next 8 hours.
    static func showNextNote(title: String?, at date: Date?) {
        let show = AppSettings.showNextNoteActivity
        Task.detached { await refreshNextNote(title: title, date: date, show: show) }
    }

    // MARK: Work

    private static func requestMeeting(start: Date) async {
        guard enabled else { return }
        let state = Attributes.ContentState(title: String(localized: "Meeting"), date: start)
        _ = try? Activity.request(attributes: Attributes(kind: .meeting),
                                  content: ActivityContent(state: state, staleDate: nil))
    }

    private static func refreshMeeting(start: Date, paused: Bool) async {
        let state = Attributes.ContentState(title: String(localized: "Meeting"), date: start, paused: paused)
        for a in activities(.meeting) {
            await a.update(ActivityContent(state: state, staleDate: nil))
        }
    }

    private static func end(_ kind: Attributes.Kind) async {
        for a in activities(kind) {
            await a.end(nil, dismissalPolicy: .immediate)
        }
    }

    private static func refreshNextNote(title: String?, date: Date?, show: Bool) async {
        guard show, enabled, let title, let date,
              date > .now, date.timeIntervalSinceNow < 8 * 3_600 else {
            await end(.nextNote)
            return
        }
        let content = ActivityContent(state: Attributes.ContentState(title: title, date: date),
                                      staleDate: date.addingTimeInterval(60))
        let current = activities(.nextNote)
        if let first = current.first {
            await first.update(content)
            for extra in current.dropFirst() { await extra.end(nil, dismissalPolicy: .immediate) }
        } else {
            _ = try? Activity.request(attributes: Attributes(kind: .nextNote), content: content)
        }
    }
}
