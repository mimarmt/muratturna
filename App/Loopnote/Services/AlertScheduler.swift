import BackgroundTasks
import CoreLocation
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

        // Notes whose schedule ran out are NOT archived automatically: they stay in the list
        // until the user marks them done, and the morning follow-up mentions them.
        for note in notes where (note.snoozedUntil ?? .distantFuture) < now {
            note.snoozedUntil = nil
        }
        try? context.save()

        let byID = Dictionary(notes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let placeNotes = Array(notes.filter { $0.hasLocation && $0.isActive }.prefix(LocationService.maxRegions))
        let capacity = AlertPlanner.systemNotificationLimit - 4 - placeNotes.count
        let plan = AlertPlanner(quietHours: AppSettings.quietHours, capacity: capacity)
            .plan(notes.map(\.plannable), now: now)

        center.removeAllPendingNotificationRequests()
        CriticalAlarms.cancelAll()
        let alarmsAllowed = CriticalAlarms.isAuthorized
        var alarmCount = 0
        var usedSounds = Set<String>()

        let awaiting = notes.filter { $0.isAwaitingConfirmation && !($0.project?.isMuted ?? false) }
        let morning = Self.nextMorning(after: now, quiet: AppSettings.quietHours)
        let awaitingTitles = awaiting.prefix(5).map(\.textToSpeak)
        let followUpSpoken = String(localized: "\(awaiting.count) notes are still waiting to be marked done.")
            + " " + awaitingTitles.joined(separator: ". ")
        var followUpMerged = false

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
                if let photo = note.photoFileName, let url = PhotoStore.attachmentCopy(photo),
                   let attachment = try? UNNotificationAttachment(identifier: "photo", url: url) {
                    content.attachments = [attachment]
                }
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
                var said = String(localized: "\(items.count) notes waited for you overnight.") + " "
                    + titles.joined(separator: ". ")
                if !awaiting.isEmpty && abs(alert.date.timeIntervalSince(morning)) < 60 {
                    content.body += "\n\n" + String(localized: "Not done yet:") + "\n"
                        + awaitingTitles.map { "○ " + $0 }.joined(separator: "\n")
                    said += ". " + followUpSpoken
                    followUpMerged = true
                }
                spoken = said
            }

            if let sound = await SpeechRenderer.shared.soundFile(for: spoken, language: language) {
                content.sound = UNNotificationSound(named: UNNotificationSoundName(sound))
                usedSounds.insert(sound)
            } else {
                content.sound = .default
            }

            // Critical notes ring as alarms (through Silent mode and Focus) instead of notifications.
            if case .note(let id, _, true) = alert.kind, alarmsAllowed, alarmCount < CriticalAlarms.maxAlarms {
                let file = await SpeechRenderer.shared.soundFile(for: spoken, language: language)
                if let file { usedSounds.insert(file) }
                if await CriticalAlarms.schedule(noteID: id, title: spoken, at: alert.date, soundFile: file) {
                    alarmCount += 1
                    continue
                }
            }

            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                                        from: alert.date)
            let request = UNNotificationRequest(
                identifier: alert.id, content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
            try? await center.add(request)
        }

        // Place reminders: iOS wakes them on region entry/exit, every time, until done.
        for note in placeNotes {
            guard let lat = note.locationLatitude, let lon = note.locationLongitude else { continue }
            let content = UNMutableNotificationContent()
            let spoken = note.textToSpeak
            content.title = spoken
            content.subtitle = note.locationName ?? note.project?.name ?? ""
            if note.details != spoken { content.body = String(note.details.prefix(240)) }
            content.categoryIdentifier = Self.noteCategory
            content.threadIdentifier = note.project?.id.uuidString ?? "inbox"
            content.userInfo = ["noteID": note.id.uuidString]
            content.interruptionLevel = note.isCritical ? .timeSensitive : .active
            if let photo = note.photoFileName, let url = PhotoStore.attachmentCopy(photo),
               let attachment = try? UNNotificationAttachment(identifier: "photo", url: url) {
                content.attachments = [attachment]
            }
            let language = note.languageCode ?? LanguageDetector.speechLanguage(for: spoken)
            if let sound = await SpeechRenderer.shared.soundFile(for: spoken, language: language) {
                content.sound = UNNotificationSound(named: UNNotificationSoundName(sound))
                usedSounds.insert(sound)
            } else {
                content.sound = .default
            }
            let region = CLCircularRegion(center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                                          radius: max(100, note.locationRadius),
                                          identifier: "place.\(note.id.uuidString)")
            region.notifyOnEntry = note.locationOnArrive
            region.notifyOnExit = !note.locationOnArrive
            try? await center.add(UNNotificationRequest(
                identifier: "place.\(note.id.uuidString)", content: content,
                trigger: UNLocationNotificationTrigger(region: region, repeats: true)))
        }

        // Morning follow-up for notes that spoke but were never marked done.
        if !awaiting.isEmpty && !followUpMerged {
            let content = UNMutableNotificationContent()
            content.title = String(localized: "Not done yet")
            content.body = awaitingTitles.map { "○ " + $0 }.joined(separator: "\n")
            content.categoryIdentifier = Self.digestCategory
            content.threadIdentifier = "digest"
            if let sound = await SpeechRenderer.shared.soundFile(for: followUpSpoken,
                                                                 language: LanguageDetector.fallback) {
                content.sound = UNNotificationSound(named: UNNotificationSoundName(sound))
                usedSounds.insert(sound)
            } else {
                content.sound = .default
            }
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: morning)
            try? await center.add(UNNotificationRequest(
                identifier: "followup.\(Int(morning.timeIntervalSince1970))", content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)))
        }

        SpeechRenderer.shared.pruneSounds(keeping: usedSounds)
        scheduleBackgroundRefresh(horizon: plan.horizon)
    }

    /// When quiet hours end next (or 09:00 when quiet hours are off).
    static func nextMorning(after date: Date, quiet: QuietHours, calendar: Calendar = .current) -> Date {
        let wake = quiet.isEnabled ? quiet.end : TimeOfDay(hour: 9, minute: 0)
        let today = wake.on(date, calendar: calendar)
        if today > date { return today }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: date) ?? date
        return wake.on(tomorrow, calendar: calendar)
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
