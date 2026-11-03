import Foundation

/// Rule-based spoken-title extraction, used when the on-device language model
/// is unavailable (devices without Apple Intelligence, or the model is busy).
public enum SpokenTitle {
    /// Spoken titles should be readable in well under the 30 s notification-sound limit.
    public static let maxLength = 80

    public static func fallback(from text: String) -> String {
        let cleaned = text
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !cleaned.isEmpty else { return "" }

        // First sentence.
        var sentence = cleaned
        if let r = cleaned.rangeOfCharacter(from: CharacterSet(charactersIn: ".!?;")) {
            let candidate = String(cleaned[..<r.lowerBound])
            if candidate.count >= 3 { sentence = candidate }
        }
        sentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))

        guard sentence.count > maxLength else { return sentence }

        // Cut at the last word boundary that fits.
        let prefix = sentence.prefix(maxLength)
        if let space = prefix.lastIndex(of: " ") {
            return String(prefix[..<space]) + "…"
        }
        return String(prefix) + "…"
    }
}
