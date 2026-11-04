import ActivityKit
import AlarmKit
import AppIntents
import Foundation
import SwiftUI

/// Data carried by a Loopnote alarm.
struct LoopnoteAlarmMetadata: AlarmMetadata {
    var noteID: UUID
}

/// Critical notes ring as AlarmKit alarms: full-screen, through Silent mode and Focus.
@MainActor
enum CriticalAlarms {
    /// Upcoming critical occurrences scheduled as alarms at any time.
    static let maxAlarms = 12

    static var isAuthorized: Bool { AlarmManager.shared.authorizationState == .authorized }

    static func requestAuthorization() async -> Bool {
        (try? await AlarmManager.shared.requestAuthorization()) == .authorized
    }

    static func cancelAll() {
        for alarm in (try? AlarmManager.shared.alarms) ?? [] {
            try? AlarmManager.shared.cancel(id: alarm.id)
        }
    }

    /// Schedules one alarm; returns false when it could not be scheduled.
    @discardableResult
    static func schedule(noteID: UUID, title: String, at date: Date, soundFile: String?) async -> Bool {
        let alert = AlarmPresentation.Alert(
            title: LocalizedStringResource("\(title)"),
            stopButton: AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.circle"),
            secondaryButton: AlarmButton(text: "Done", textColor: .black, systemImageName: "checkmark.circle"),
            secondaryButtonBehavior: .custom)
        let attributes = AlarmAttributes<LoopnoteAlarmMetadata>(
            presentation: AlarmPresentation(alert: alert),
            metadata: LoopnoteAlarmMetadata(noteID: noteID),
            tintColor: Theme.amber)
        let configuration = AlarmManager.AlarmConfiguration<LoopnoteAlarmMetadata>(
            schedule: .fixed(date),
            attributes: attributes,
            secondaryIntent: CompleteNoteIntent(noteID: noteID),
            sound: soundFile.map { .named($0) } ?? .default)
        do {
            _ = try await AlarmManager.shared.schedule(id: UUID(), configuration: configuration)
            return true
        } catch {
            return false
        }
    }
}

/// "Done" on the alarm screen: completes the note without opening the app.
struct CompleteNoteIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Mark note done"
    static let isDiscoverable = false

    @Parameter(title: "Note")
    var noteID: String

    init() { noteID = "" }
    init(noteID: UUID) { self.noteID = noteID.uuidString }

    @MainActor
    func perform() async throws -> some IntentResult {
        await AlertScheduler.shared.handle(action: AlertScheduler.Action.complete, noteID: UUID(uuidString: noteID))
        return .result()
    }
}
