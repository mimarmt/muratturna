import Foundation
import FoundationModels
import LoopnoteCore

/// Turns a long dictated note into a short sentence that is read aloud.
/// Uses the on-device Apple Foundation Model; falls back to the first sentence.
enum TitleSummarizer {
    static var isModelAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    static func spokenTitle(for text: String, language: String) async -> String {
        let fallback = SpokenTitle.fallback(from: text)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 50, isModelAvailable else { return fallback }

        let languageName = Locale(identifier: "en").localizedString(forIdentifier: language) ?? language
        let session = LanguageModelSession(instructions: """
            You write reminder titles that will be read aloud by a phone.
            Reply with ONE short imperative sentence of at most 10 words, in \(languageName).
            Keep names, places and numbers. No quotes, no emoji, no trailing period.
            """)
        do {
            let response = try await session.respond(to: trimmed)
            let title = response.content
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'.“”"))
            guard !title.isEmpty, title.count <= SpokenTitle.maxLength * 2 else { return fallback }
            return title
        } catch {
            return fallback
        }
    }
}
