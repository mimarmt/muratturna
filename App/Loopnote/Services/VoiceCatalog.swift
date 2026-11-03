import AVFoundation

/// Chooses the voice for a language: the user's pick, then Personal Voice (when enabled and the
/// language matches), then the highest-quality installed system voice.
enum VoiceCatalog {
    static let languages = ["tr-TR", "en-US", "de-DE"]

    static func voices(for language: String) -> [AVSpeechSynthesisVoice] {
        let prefix = String(language.prefix(2))
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(prefix) && !$0.voiceTraits.contains(.isNoveltyVoice) }
            .sorted {
                if $0.quality != $1.quality { return $0.quality.rawValue > $1.quality.rawValue }
                return $0.name < $1.name
            }
    }

    static func voice(for language: String, allowPersonal: Bool) -> AVSpeechSynthesisVoice? {
        let all = voices(for: language)
        if let id = AppSettings.voiceIdentifier(for: language),
           let chosen = all.first(where: { $0.identifier == id }) {
            return chosen
        }
        if allowPersonal,
           AVSpeechSynthesizer.personalVoiceAuthorizationStatus == .authorized,
           let personal = all.first(where: { $0.voiceTraits.contains(.isPersonalVoice) }) {
            return personal
        }
        let regular = all.filter { !$0.voiceTraits.contains(.isPersonalVoice) }
        let exact = regular.filter { $0.language == language }
        return (exact.isEmpty ? regular : exact).first ?? AVSpeechSynthesisVoice(language: language)
    }

    /// True when only the compact (lowest quality) voice is installed for the language.
    static func onlyCompactInstalled(for language: String) -> Bool {
        let regular = voices(for: language).filter { !$0.voiceTraits.contains(.isPersonalVoice) }
        return !regular.isEmpty && regular.allSatisfy { $0.quality == .default }
    }

    static func qualityLabel(_ v: AVSpeechSynthesisVoice) -> String {
        if v.voiceTraits.contains(.isPersonalVoice) { return String(localized: "Personal Voice") }
        switch v.quality {
        case .premium: return String(localized: "Premium")
        case .enhanced: return String(localized: "Enhanced")
        default: return String(localized: "Compact")
        }
    }

    static func requestPersonalVoice() async -> Bool {
        await withCheckedContinuation { cont in
            AVSpeechSynthesizer.requestPersonalVoiceAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
    }
}
