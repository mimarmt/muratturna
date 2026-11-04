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

struct StartMeetingIntent: AppIntent {
    static let title: LocalizedStringResource = "Start meeting recording"
    static let description = IntentDescription("Opens Loopnote and starts recording a meeting.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.tab = .meetings
        AppRouter.shared.showMeetingRecorder = true
        return .result()
    }
}

struct NewVoiceNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "New voice note"
    static let description = IntentDescription("Opens Loopnote and starts dictating a living note.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.tab = .notes
        AppRouter.shared.startVoiceNote = true
        return .result()
    }
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
