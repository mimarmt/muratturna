import Foundation

/// The app's latest note snapshot, shared with the widgets through the App Group.
///
/// The app writes it every time it reschedules; widgets only read it. The snapshot reuses
/// `WatchNote`, the same small value the Apple Watch receives.
enum SharedNotes {
    static let appGroup = "group.com.muratturna.loopnote"
    static let widgetKind = "com.muratturna.loopnote.notes"
    private static let key = "notes.snapshot"

    private static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    static func save(_ notes: [WatchNote]) {
        guard let data = try? JSONEncoder().encode(notes) else { return }
        defaults?.set(data, forKey: key)
    }

    static func load() -> [WatchNote] {
        guard let data = defaults?.data(forKey: key),
              let notes = try? JSONDecoder().decode([WatchNote].self, from: data) else { return [] }
        return notes
    }
}
