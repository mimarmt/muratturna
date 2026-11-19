import AppIntents
import CoreSpotlight
import Foundation
import LoopnoteCore
import SwiftData

// Siri, Shortcuts and Spotlight: notes and projects as entities, plus intents that read,
// add and complete notes without opening the app.

// MARK: Entities

struct ProjectEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Project"
    static let defaultQuery = ProjectQuery()

    let id: UUID
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct ProjectQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [ProjectEntity] {
        NoteStore.projects().filter { identifiers.contains($0.id) }.map(ProjectEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [ProjectEntity] {
        NoteStore.projects()
            .filter { $0.name.localizedStandardContains(string) }
            .map(ProjectEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [ProjectEntity] {
        NoteStore.projects().map(ProjectEntity.init)
    }
}

extension ProjectEntity {
    init(_ project: Project) { self.init(id: project.id, name: project.name) }
}

struct NoteEntity: IndexedEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Note"
    static let defaultQuery = NoteQuery()

    let id: UUID
    @Property(title: "Title") var title: String
    @Property(title: "Details") var details: String
    @Property(title: "Project") var projectName: String
    @Property(title: "Next reminder") var next: Date?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)",
                              subtitle: projectName.isEmpty ? nil : "\(projectName)",
                              image: .init(systemName: "waveform"))
    }

    init(_ note: Note) {
        id = note.id
        title = note.textToSpeak
        details = note.details
        projectName = note.project?.name ?? ""
        next = note.nextOccurrence()
    }
}

struct NoteQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [NoteEntity] {
        NoteStore.activeNotes().filter { identifiers.contains($0.id) }.map(NoteEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [NoteEntity] {
        NoteStore.activeNotes()
            .filter { $0.textToSpeak.localizedStandardContains(string) || $0.details.localizedStandardContains(string) }
            .map(NoteEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [NoteEntity] {
        Array(NoteStore.activeNotes().prefix(20)).map(NoteEntity.init)
    }
}

// MARK: Intents

/// "Read my Yalova notes": Siri reads the active notes, optionally of one project.
struct ReadNotesIntent: AppIntent {
    static let title: LocalizedStringResource = "Read my notes"
    static let description = IntentDescription("Reads your active notes aloud, optionally only one project's.")

    @Parameter(title: "Project")
    var project: ProjectEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Read notes of \(\.$project)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<[NoteEntity]> {
        var notes = NoteStore.activeNotes()
        if let project { notes = notes.filter { $0.project?.id == project.id } }
        Trace.log("siri: read notes (\(notes.count))")
        if notes.isEmpty {
            if let project {
                return .result(value: [], dialog: "You have no active notes in \(project.name).")
            }
            return .result(value: [], dialog: "You have no active notes.")
        }
        let spoken = notes.prefix(8).enumerated()
            .map { "\($0.offset + 1). \($0.element.textToSpeak)" }
            .joined(separator: ". ")
        let more = notes.count > 8 ? " " + String(localized: "And \(notes.count - 8) more.") : ""
        let header: String = project.map { String(localized: "\(notes.count) notes in \($0.name).") }
            ?? String(localized: "You have \(notes.count) notes.")
        return .result(value: notes.map(NoteEntity.init), dialog: "\(header) \(spoken)\(more)")
    }
}

/// "Add a note to Loopnote: check the scaffolding tomorrow at ten".
struct AddNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Add a note"
    static let description = IntentDescription(
        "Adds a living note. A date or time in the text sets the reminder; otherwise it speaks every morning at 9.")

    @Parameter(title: "Note", requestValueDialog: "What should Loopnote remind you of?")
    var text: String

    @Parameter(title: "Project")
    var project: ProjectEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$text) to \(\.$project)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .result(dialog: "The note is empty.") }
        if !ProStore.shared.isPro, NoteStore.activeNotes().count >= ProStore.freeNoteLimit {
            return .result(dialog: "You have reached the free limit of \(ProStore.freeNoteLimit) notes. Open Loopnote to upgrade.")
        }
        let note = await NoteStore.add(text: trimmed, projectID: project?.id)
        Trace.log("siri: note added")
        if let next = note.nextOccurrence() {
            let when = next.formatted(date: .abbreviated, time: .shortened)
            return .result(dialog: "Added. Loopnote will remind you \(when).")
        }
        return .result(dialog: "Added.")
    }
}

/// "Mark the scaffolding note done".
struct MarkNoteDoneIntent: AppIntent {
    static let title: LocalizedStringResource = "Mark a note done"
    static let description = IntentDescription("Marks a note done so it stops reminding you.")

    @Parameter(title: "Note")
    var note: NoteEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Mark \(\.$note) done")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await AlertScheduler.shared.handle(action: AlertScheduler.Action.complete, noteID: note.id)
        return .result(dialog: "Done. \(note.title) will not remind you again.")
    }
}

/// Opening a note from Spotlight or Shortcuts shows the notes list.
struct OpenNoteIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open note"

    @Parameter(title: "Note")
    var target: NoteEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.tab = .notes
        return .result()
    }
}

// MARK: Store access

@MainActor
enum NoteStore {
    static var context: ModelContext { Persistence.container.mainContext }

    static func activeNotes() -> [Note] {
        let all = (try? context.fetch(FetchDescriptor<Note>(predicate: #Predicate { $0.completedAt == nil }))) ?? []
        return all.filter(\.isActive)
            .sorted { ($0.nextOccurrence() ?? .distantFuture) < ($1.nextOccurrence() ?? .distantFuture) }
    }

    static func projects() -> [Project] {
        (try? context.fetch(FetchDescriptor<Project>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
    }

    /// Creates a note the way the Watch does: a detected date makes a one-time reminder,
    /// otherwise it speaks every morning at 9 until done.
    static func add(text: String, projectID: UUID?) async -> Note {
        let language = LanguageDetector.speechLanguage(for: text)
        let title = await TitleSummarizer.spokenTitle(for: text, language: language)
        let schedule: NoteSchedule
        if let date = MeetingDetailView.detectDate(in: text), date > .now {
            schedule = NoteSchedule(start: date, rule: .once)
        } else {
            schedule = NoteSchedule(start: .now, rule: .daily(times: [TimeOfDay(hour: 9, minute: 0)]))
        }
        let project = projectID.flatMap { id in projects().first { $0.id == id } }
        let note = Note(details: text, spokenTitle: title, schedule: schedule,
                        languageCode: language, project: project)
        context.insert(note)
        try? context.save()
        await AlertScheduler.shared.reschedule()
        return note
    }

    /// Keeps Spotlight and Siri's project names in step with the app.
    static func refreshSystemIndexes() {
        let notes = activeNotes().map(NoteEntity.init)
        Task.detached(priority: .utility) {
            // Only notes are indexed, so clearing the app's items drops completed ones.
            try? await CSSearchableIndex.default().deleteAllSearchableItems()
            try? await CSSearchableIndex.default().indexAppEntities(notes)
        }
        LoopnoteShortcuts.updateAppShortcutParameters()
    }
}
