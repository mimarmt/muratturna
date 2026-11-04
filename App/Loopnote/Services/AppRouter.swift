import AppIntents
import Observation

/// App-wide navigation requests (from App Shortcuts, Siri and the Action button).
@MainActor
@Observable
final class AppRouter {
    static let shared = AppRouter()

    enum Tab: Hashable { case notes, meetings }

    var tab: Tab = .notes
    var showMeetingRecorder = false
    var startVoiceNote = false
    var openMeetingID: UUID?
}

struct LoopnoteShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartMeetingIntent(),
                    phrases: ["Start a meeting in \(.applicationName)",
                              "Record a meeting with \(.applicationName)"],
                    shortTitle: "Start meeting",
                    systemImageName: "person.2.wave.2")
        AppShortcut(intent: NewVoiceNoteIntent(),
                    phrases: ["New note in \(.applicationName)",
                              "Add a voice note to \(.applicationName)"],
                    shortTitle: "Voice note",
                    systemImageName: "mic")
    }
}
