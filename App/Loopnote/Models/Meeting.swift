import Foundation
import SwiftData

/// One action from a meeting: who does what, by when. Can become a living note.
struct MeetingAction: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var task: String
    var owner: String
    var due: String
    var noteID: UUID?
}

/// A recorded meeting with its transcript and AI minutes.
@Model
final class Meeting {
    enum Status: String, Codable, Sendable {
        case recorded, transcribing, summarizing, ready, failed
    }

    var id: UUID = UUID()
    var title: String = ""
    var createdAt: Date = Date.now
    var duration: Double = 0
    var audioFileName: String?
    var language: String?
    var transcript: String = ""
    var summary: String = ""
    var decisionsData: Data?
    var actionsData: Data?
    var statusRaw: String = Status.recorded.rawValue
    var errorMessage: String?
    var project: Project?

    init(title: String, audioFileName: String, duration: Double, language: String) {
        self.title = title
        self.audioFileName = audioFileName
        self.duration = duration
        self.language = language
    }

    var status: Status {
        get { Status(rawValue: statusRaw) ?? .recorded }
        set { statusRaw = newValue.rawValue }
    }

    var decisions: [String] {
        get { decisionsData.flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? [] }
        set { decisionsData = try? JSONEncoder().encode(newValue) }
    }

    var actions: [MeetingAction] {
        get { actionsData.flatMap { try? JSONDecoder().decode([MeetingAction].self, from: $0) } ?? [] }
        set { actionsData = try? JSONEncoder().encode(newValue) }
    }

    var audioURL: URL? {
        audioFileName.map { Meeting.directory.appendingPathComponent($0) }
    }

    static var directory: URL {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Meetings", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
