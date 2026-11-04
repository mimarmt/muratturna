import AppIntents

// Shared by the app and the widget extension (Control Center / Lock Screen controls).
// Both intents open the app; the work happens in the app process.

struct StartMeetingIntent: AppIntent {
    static let title: LocalizedStringResource = "Start meeting recording"
    static let description = IntentDescription("Opens Loopnote and starts recording a meeting.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        AppRouter.shared.tab = .meetings
        AppRouter.shared.showMeetingRecorder = true
        #endif
        return .result()
    }
}

struct NewVoiceNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "New voice note"
    static let description = IntentDescription("Opens Loopnote and starts dictating a living note.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION
        AppRouter.shared.tab = .notes
        AppRouter.shared.startVoiceNote = true
        #endif
        return .result()
    }
}
