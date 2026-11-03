import BackgroundTasks
import Foundation
import SwiftData
import UserNotifications
import LoopnoteCore

/// Bridges the planner to iOS: renders each note's voice and schedules local notifications.
@MainActor
final class AlertScheduler {
    static let shared = AlertScheduler()

    static let noteCategory = "loopnote.note"
    static let digestCategory = "loopnote.digest"
    static let refreshTaskID = "com.muratturna.loopnote.replan"

    enum Action {
        static let complete = "loopnote.complete"
        static let snooze10 = "loopnote.snooze10"
        static let snooze60 = "loopnote.snooze60"
        static let tomorrow = "loopnote.tomorrow"
        static let replay = "loopnote.replay"
    }

    private let center = UNUserNotificationCenter.current()
    private var isRunning = false
    private var needsAnotherPass = false

    // MARK: Setup

    func registerCategories() {
        func action(_ id: String, _ title: String, _ symbol: String,
                    _ options: UNNotificationActionOptions = []) -> UNNotificationAction {
            UNNotificationAction(identifier: id, title: title, options: options,
                                 icon: UNNotificationActionIcon(systemImageName: symbol))
        }
        let note = UNNotificationCategory(
            identifier: Self.noteCategory,
            actions: [
                action(Action.complete, String(localized: "Done"), "checkmark.circle"),
                action(Action.snooze10, String(localized: "Snooze 10 min"), "clock"),
                action(Action.snooze60, String(localized: "Snooze 1 hour"), "clock.arrow.circlepath"),
                action(Action.tomorrow, String(localized: "Tomorrow"), "sunrise"),
                action(Action.replay, String(localized: "Listen again"), "speaker.wave.2", [.foreground])
            ],
            intentIdentifiers: [], options: [])
        let digest = UNNotificationCategory(
            identifier: Self.digestCategory,
            actions: [action(Action.replay, String(localized: "Listen again"), "speaker.wave.2", [.foreground])],
            intentIdentifiers: [], options: [])
        center.setNotificationCategories([note, digest])
    }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    // MARK: Scheduling

    /// Rebuilds all pending notifications. Safe to call often; overlapping calls are coalesced.
    func reschedule() async {
        if isRunning { needsAnotherPass = true; return }
        isRunning = true
        repeat {
            needsAnotherPass = false
            await performReschedule()
        } while needsAnotherPass
        isRunning = false
    }

    private func performReschedule() async {
        let context = Persistence.container.mainContext
        let now = Date.now
        let notes = (try? context.fetch(FetchDescriptor<Note>())) ?? []

        // Notes whose end date / count has passed go to the archive on their own.
        for note in notes where !note.isCompleted && note.hasEnded(at: now) {
            note.completedAt = now
        }
        for note in notes where (note.snoozedUntil ?? .distantFuture) < now {
            note.snoozedUntil = nil
        }
        try? context.save()

        let byID = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let plan = AlertPlanner(quietHours: AppSettings.quietHours).plan(notes.map(\.plannable), now: now)

        center.removeAllPendingNotificationRequests()
        var usedSounds = Set<String>()

        for alert in plan.alerts {
            let content = UNMutableNotificationContent()
            let spoken: String
            let language: String

            switch alert.kind {
            case .note(let id, _, let critical):
                guard let note = byID[id] else { continue }
                spoken = note.textToSpeak
                language = note.languageCode ?? LanguageDetector.speechLanguage(for: spoken)
                content.title = spoken
                if note.details != spoken { content.body = String(note.details.prefix(240)) }
                if let project = note.project { content.subtitle = project.name }
                content.categoryIdentifier = Self.noteCategory
                content.threadIdentifier = note.project?.id.uuidString ?? "inbox"
                content.userInfo = ["noteID": id.uuidString]
                content.interruptionLevel = critical ? .timeSensitive : .active
                content.relevanceScore = critical ? 1 : 0.5

            case .digest(let ids):
                let items = ids.compactMap { byID[$0] }
                guard !items.isEmpty else { continue }
                language = LanguageDetector.fallback
                let titles = items.prefix(5).map(\.textToSpeak)
                content.title = String(localized: "Good morning")
                content.body = titles.map { "• " + $0 }.joined(separator: "\n")
                content.categoryIdentifier = Self.digestCategory
                content.threadIdentifier = "digest"
                spoken = String(localized: "\(items.count) notes waited for you overnight.") + " "
                    + titles.joined(separator: ". ")
            }

            if let sound = await SpeechRenderer.shared.soundFile(for: spoken, language: language) {
                content.sound = UNNotificationSound(named: UNNotificationSoundName(sound))
                usedSounds.insert(sound)
            } else {
                content.sound = .default
            }

            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                                        from: alert.date)
            let request = UNNotificationRequest(
                identifier: alert.id, content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
            try? await center.add(request)
        }

        SpeechRenderer.shared.pruneSounds(keeping: usedSounds)
        scheduleBackgroundRefresh(horizon: plan.horizon)
    }

    private func scheduleBackgroundRefresh(horizon: Date?) {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)
        let target = horizon.map { $0.addingTimeInterval(-3_600) } ?? Date.now.addingTimeInterval(6 * 3_600)
        request.earliestBeginDate = max(target, Date.now.addingTimeInterval(15 * 60))
        try? BGTaskScheduler.shared.submit(request)
    }

    // MARK: Actions

    func handle(action: String, noteID: UUID?) async {
        let context = Persistence.container.mainContext
        var note: Note?
        if let noteID {
            let target = noteID
            note = try? context.fetch(FetchDescriptor<Note>(predicate: #Predicate<Note> { $0.id == target })).first
        }
        let now = Date.now

        switch action {
        case Action.complete:
            note?.completedAt = now
        case Action.snooze10:
            note?.snoozedUntil = now.addingTimeInterval(10 * 60)
        case Action.snooze60:
            note?.snoozedUntil = now.addingTimeInterval(60 * 60)
        case Action.tomorrow:
            let quiet = AppSettings.quietHours
            let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now) ?? now
            let wake = quiet.isEnabled ? quiet.end : TimeOfDay(hour: 9, minute: 0)
            note?.snoozedUntil = wake.on(tomorrow, calendar: .current)
        case Action.replay:
            if let note {
                SpeechRenderer.shared.speakNow(note.textToSpeak,
                                               language: note.languageCode ?? LanguageDetector.fallback)
            }
        default:
            break
        }
        try? context.save()
        await reschedule()
    }
}

/// Receives notification taps and action buttons.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        let id = (response.notification.request.content.userInfo["noteID"] as? String).flatMap(UUID.init)
        await AlertScheduler.shared.handle(action: action, noteID: id)
    }
}
