import Foundation
import SwiftData
import LoopnoteCore

/// A colored group of notes. Muting a project silences all of its notes at once.
@Model
final class Project {
    var id: UUID = UUID()
    var name: String = ""
    var colorHex: String = "#FFA53D"
    var isMuted: Bool = false
    var createdAt: Date = Date.now
    @Relationship(deleteRule: .nullify, inverse: \Note.project)
    var notes: [Note]? = []
    @Relationship(deleteRule: .nullify, inverse: \Meeting.project)
    var meetings: [Meeting]? = []

    init(name: String, colorHex: String = "#FFA53D") {
        self.name = name
        self.colorHex = colorHex
    }
}

/// A living note: it speaks its spoken title on its schedule until it ends or is completed.
///
/// All properties have defaults and relationships are optional so the store can sync with CloudKit.
@Model
final class Note {
    var id: UUID = UUID()
    /// The full text of the note, typed or dictated.
    var details: String = ""
    /// Short sentence that is read aloud.
    var spokenTitle: String = ""
    /// BCP-47 code used for speech, e.g. "tr-TR". Nil means "detect".
    var languageCode: String?
    var createdAt: Date = Date.now
    var scheduleData: Data?
    var isCritical: Bool = false
    var completedAt: Date?
    var snoozedUntil: Date?
    /// JPEG in Documents/Photos shown in the editor and as the notification thumbnail.
    var photoFileName: String?
    /// Location reminder: speaks when arriving at (or leaving) this place, every time, until done.
    var locationLatitude: Double?
    var locationLongitude: Double?
    var locationRadius: Double = 150
    var locationName: String?
    var locationOnArrive: Bool = true
    var project: Project?

    init(details: String, spokenTitle: String, schedule: NoteSchedule,
         languageCode: String? = nil, isCritical: Bool = false, project: Project? = nil) {
        self.details = details
        self.spokenTitle = spokenTitle
        self.languageCode = languageCode
        self.isCritical = isCritical
        self.project = project
        self.schedule = schedule
    }

    var schedule: NoteSchedule {
        get {
            if let data = scheduleData, let s = try? JSONDecoder().decode(NoteSchedule.self, from: data) {
                return s
            }
            return NoteSchedule(start: createdAt, rule: .once)
        }
        set { scheduleData = try? JSONEncoder().encode(newValue) }
    }

    var isCompleted: Bool { completedAt != nil }

    /// Whether this note should currently speak.
    var isActive: Bool { !isCompleted && !(project?.isMuted ?? false) }

    var hasLocation: Bool { locationLatitude != nil && locationLongitude != nil }

    var plannable: PlannableNote {
        // Location notes are delivered by region triggers, not by the time planner.
        PlannableNote(id: id, schedule: schedule, isActive: isActive && !hasLocation,
                      snoozedUntil: snoozedUntil, isCritical: isCritical)
    }

    func nextOccurrence(after date: Date = .now, calendar: Calendar = .current) -> Date? {
        if hasLocation { return nil }
        if let s = snoozedUntil, s > date { return s }
        return schedule.occurrences(after: date, limit: 1, calendar: calendar).first?.date
    }

    /// The note has finished on its own (end date or count reached).
    func hasEnded(at date: Date = .now, calendar: Calendar = .current) -> Bool {
        if hasLocation { return false }
        return nextOccurrence(after: date, calendar: calendar) == nil
    }

    /// Its schedule has run out (end date, count or a one-time reminder that already spoke)
    /// but nobody marked it done. Such notes stay in the list until they are completed.
    var isAwaitingConfirmation: Bool { !isCompleted && hasEnded() }

    var textToSpeak: String { spokenTitle.isEmpty ? SpokenTitle.fallback(from: details) : spokenTitle }
}

/// Shared SwiftData container, also used by the notification delegate and background tasks.
enum Persistence {
    static let container: ModelContainer = {
        let schema = Schema([Note.self, Project.self, Meeting.self])
        let config = ModelConfiguration(schema: schema, cloudKitDatabase: .automatic)
        StoreBackup.daily(storeURL: config.url)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            // iCloud unavailable or misconfigured: open the same file locally.
            let local = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
            if let c = try? ModelContainer(for: schema, configurations: [local]) { return c }
            // The store cannot be opened (e.g. a failed migration). Keep it for recovery
            // instead of crashing, then start a fresh one.
            StoreBackup.quarantine(storeURL: config.url)
            return try! ModelContainer(for: schema, configurations: [local])
        }
    }()
}

/// Copies of the SwiftData store so an update can never silently lose notes.
enum StoreBackup {
    static let keep = 3

    static var directory: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func files(for store: URL) -> [URL] {
        ["", "-wal", "-shm"].map { URL(fileURLWithPath: store.path + $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// At most one backup per day; the oldest beyond `keep` are removed.
    static func daily(storeURL: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: storeURL.path) else { return }
        let day = Date.now.formatted(.iso8601.year().month().day())
        let target = directory.appendingPathComponent(day, isDirectory: true)
        guard !fm.fileExists(atPath: target.path) else { return }
        try? fm.createDirectory(at: target, withIntermediateDirectories: true)
        for file in files(for: storeURL) {
            try? fm.copyItem(at: file, to: target.appendingPathComponent(file.lastPathComponent))
        }
        let all = ((try? fm.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { !$0.hasPrefix("failed-") }.sorted()
        for old in all.dropLast(keep) {
            try? fm.removeItem(at: directory.appendingPathComponent(old))
        }
    }

    /// Moves an unreadable store aside (kept for manual recovery).
    static func quarantine(storeURL: URL) {
        let fm = FileManager.default
        let target = directory.appendingPathComponent("failed-\(Int(Date.now.timeIntervalSince1970))", isDirectory: true)
        try? fm.createDirectory(at: target, withIntermediateDirectories: true)
        for file in files(for: storeURL) {
            try? fm.moveItem(at: file, to: target.appendingPathComponent(file.lastPathComponent))
        }
    }
}
