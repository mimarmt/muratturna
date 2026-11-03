import Foundation
import NaturalLanguage

/// Detects whether a note is Turkish, English or German so it is read in the right voice.
enum LanguageDetector {
    static let supported: [NLLanguage: String] = [
        .turkish: "tr-TR",
        .english: "en-US",
        .german: "de-DE"
    ]

    static func speechLanguage(for text: String) -> String {
        let r = NLLanguageRecognizer()
        r.languageConstraints = Array(supported.keys)
        r.processString(text)
        if let lang = r.dominantLanguage, let code = supported[lang] {
            return code
        }
        return fallback
    }

    /// The user's preferred language among the supported ones, else English.
    static var fallback: String {
        for id in Locale.preferredLanguages {
            let code = Locale(identifier: id).language.languageCode?.identifier ?? ""
            switch code {
            case "tr": return "tr-TR"
            case "de": return "de-DE"
            case "en": return "en-US"
            default: continue
            }
        }
        return "en-US"
    }
}
