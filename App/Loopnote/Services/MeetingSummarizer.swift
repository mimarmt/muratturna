import Foundation
import FoundationModels

/// Meeting minutes produced by the on-device model.
struct MeetingMinutes: Sendable {
    var title: String
    var summary: String
    var decisions: [String]
    var actions: [MeetingAction]
}

@Generable
struct GeneratedMinutes {
    @Guide(description: "A short meeting title, at most 6 words")
    var title: String
    @Guide(description: "A 3 to 5 sentence summary of what was discussed")
    var summary: String
    @Guide(description: "Decisions that were agreed in the meeting; empty if none")
    var decisions: [String]
    @Guide(description: "Concrete follow-up tasks mentioned in the meeting")
    var actions: [GeneratedAction]
}

@Generable
struct GeneratedAction {
    @Guide(description: "The task as a short imperative sentence")
    var task: String
    @Guide(description: "Who is responsible, or empty if not said")
    var owner: String
    @Guide(description: "When it is due as said in the meeting (e.g. 'Friday', 'next week'), or empty")
    var due: String
}

/// Summarizes long transcripts within the on-device context window by
/// condensing them chunk by chunk, then writing the minutes from the notes.
enum MeetingSummarizer {
    static let chunkSize = 2_500

    static func minutes(for transcript: String, language: String) async -> MeetingMinutes {
        let languageName = Locale(identifier: "en").localizedString(forIdentifier: language) ?? language
        // iOS 27: Apple's larger server model (Private Cloud Compute) reads the whole meeting at once.
        if privateCloudEnabled, #available(iOS 27.0, *),
           let pcc = await privateCloudMinutes(transcript, languageName: languageName) {
            return pcc
        }
        guard TitleSummarizer.isModelAvailable else { return fallback(transcript) }

        do {
            var material = transcript
            if transcript.count > chunkSize {
                var notes: [String] = []
                for chunk in chunks(of: transcript) {
                    let session = LanguageModelSession(instructions: """
                        You take concise notes of a part of a meeting transcript, in \(languageName).
                        Write 3 to 8 bullet points with facts, decisions, tasks, names, dates and numbers.
                        """)
                    notes.append(try await session.respond(to: chunk).content)
                }
                material = notes.joined(separator: "\n")
                if material.count > chunkSize * 2 { material = String(material.prefix(chunkSize * 2)) }
            }
            let session = LanguageModelSession(instructions: """
                You write clear meeting minutes in \(languageName) from a transcript or notes.
                Only include facts that were said. Do not invent names, dates or tasks.
                """)
            let result = try await session.respond(to: material, generating: GeneratedMinutes.self).content
            return MeetingMinutes(
                title: result.title,
                summary: result.summary,
                decisions: result.decisions.filter { !$0.isBlank },
                actions: result.actions
                    .filter { !$0.task.isBlank }
                    .map { MeetingAction(task: $0.task, owner: $0.owner, due: $0.due) })
        } catch {
            return fallback(transcript)
        }
    }

    /// Private Cloud Compute needs a managed entitlement that Apple grants on request
    /// (Small Business Program first). Without it the framework terminates the app, so the
    /// call stays off until the entitlement is in the signing profile.
    static let privateCloudEnabled = false

    @available(iOS 27.0, *)
    private static func privateCloudMinutes(_ transcript: String, languageName: String) async -> MeetingMinutes? {
        let model = PrivateCloudComputeLanguageModel()
        guard model.isAvailable, !model.quotaUsage.isLimitReached else { return nil }
        let session = LanguageModelSession(model: model, instructions: """
            You write clear, complete meeting minutes in \(languageName) from a full transcript.
            Lines may start with a speaker label such as "Speaker 1:". Only include facts that were said.
            Do not invent names, dates or tasks. Capture every concrete decision and follow-up task.
            """)
        do {
            let result = try await session.respond(to: transcript, generating: GeneratedMinutes.self).content
            return MeetingMinutes(
                title: result.title,
                summary: result.summary,
                decisions: result.decisions.filter { !$0.isBlank },
                actions: result.actions.filter { !$0.task.isBlank }
                    .map { MeetingAction(task: $0.task, owner: $0.owner, due: $0.due) })
        } catch {
            return nil
        }
    }

    static func chunks(of text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for paragraph in text.components(separatedBy: "\n\n") {
            if current.count + paragraph.count > chunkSize, !current.isEmpty {
                result.append(current)
                current = ""
            }
            if paragraph.count > chunkSize {
                var rest = Substring(paragraph)
                while !rest.isEmpty {
                    result.append(String(rest.prefix(chunkSize)))
                    rest = rest.dropFirst(chunkSize)
                }
            } else {
                current += (current.isEmpty ? "" : "\n\n") + paragraph
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// Without Apple Intelligence: first sentences as summary, no extracted actions.
    static func fallback(_ transcript: String) -> MeetingMinutes {
        let sentences = transcript.split(whereSeparator: { ".!?".contains($0) })
            .prefix(3).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return MeetingMinutes(title: "", summary: sentences.joined(separator: ". "), decisions: [], actions: [])
    }
}
