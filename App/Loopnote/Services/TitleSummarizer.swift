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
            You turn a dictated note into the short reminder sentence a phone will say out loud.
            Rules:
            - Write in \(languageName), the same language as the note.
            - At most 10 words. One sentence. No quotes, no emoji, no trailing period.
            - Keep the concrete facts: who, what, where, and any day or time.
            - Never answer with a generic phrase such as "start the reminder" or "remember this".
            Examples:
            Note: "Yarın saat 11:00'de kahvaltıda Coşkun'da olman gerekiyor unutma"
            Reminder: Yarın 11:00'de Coşkun'da kahvaltı
            Note: "Yalova'daki SPA projesi için belediyeye gidip ruhsat dosyasının eksik evraklarını sormam lazım"
            Reminder: Yalova SPA için belediyeye eksik evrakları sor
            Note: "I need to send the facade renders to Ömer before Friday"
            Reminder: Send the facade renders to Ömer before Friday
            """)
        do {
            let response = try await session.respond(to: trimmed)
            let title = response.content
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'.“”"))
            guard !title.isEmpty, title.count <= SpokenTitle.maxLength * 2,
                  !title.lowercased().contains("hatırlatma") || trimmed.lowercased().contains("hatırlatma")
            else { return fallback }
            return title
        } catch {
            return fallback
        }
    }
}
