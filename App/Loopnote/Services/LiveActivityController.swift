import ActivityKit
import Foundation

/// Starts and updates Loopnote's Live Activities (meeting recording, next note).
@MainActor
enum LiveActivityController {
    typealias Attributes = LoopnoteActivityAttributes

    private static func activities(_ kind: Attributes.Kind) -> [Activity<Attributes>] {
        Activity<Attributes>.activities.filter { $0.attributes.kind == kind }
    }

    private static var enabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    // MARK: Meeting

    static func startMeeting(at start: Date) {
        guard enabled else { return }
        let state = Attributes.ContentState(title: String(localized: "Meeting"), date: start)
        _ = try? Activity.request(attributes: Attributes(kind: .meeting),
                                  content: ActivityContent(state: state, staleDate: nil))
    }

    /// `start` is shifted on resume so the timer keeps showing elapsed recording time.
    static func updateMeeting(start: Date, paused: Bool) {
        let state = Attributes.ContentState(title: String(localized: "Meeting"), date: start, paused: paused)
        for a in activities(.meeting) {
            Task { await a.update(ActivityContent(state: state, staleDate: nil)) }
        }
    }

    static func endMeeting() {
        for a in activities(.meeting) {
            Task { await a.end(nil, dismissalPolicy: .immediate) }
        }
    }

    // MARK: Next note

    /// Shows the next note on the Lock Screen when it speaks within the next 8 hours.
    static func showNextNote(title: String?, at date: Date?) {
        let current = activities(.nextNote)
        guard AppSettings.showNextNoteActivity, enabled, let title, let date,
              date > .now, date.timeIntervalSinceNow < 8 * 3_600 else {
            for a in current { Task { await a.end(nil, dismissalPolicy: .immediate) } }
            return
        }
        let content = ActivityContent(state: Attributes.ContentState(title: title, date: date),
                                      staleDate: date.addingTimeInterval(60))
        if let first = current.first {
            Task { await first.update(content) }
            for extra in current.dropFirst() { Task { await extra.end(nil, dismissalPolicy: .immediate) } }
        } else {
            _ = try? Activity.request(attributes: Attributes(kind: .nextNote), content: content)
        }
    }
}
