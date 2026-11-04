import Foundation

/// Snapshot of a note sent from iPhone to Apple Watch.
struct WatchNote: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var title: String
    var subtitle: String
    var next: Date?
    var isCritical: Bool
    var awaitingDone: Bool
}

/// Messages between the two apps (JSON in a "data" key of WatchConnectivity payloads).
enum WatchMessage: Codable, Sendable {
    case snapshot([WatchNote])
    case complete(UUID)
    case newNote(String)

    static let key = "data"

    var payload: [String: Any] {
        [Self.key: (try? JSONEncoder().encode(self)) ?? Data()]
    }

    static func decode(_ payload: [String: Any]) -> WatchMessage? {
        guard let data = payload[key] as? Data else { return nil }
        return try? JSONDecoder().decode(WatchMessage.self, from: data)
    }
}
