import AVFoundation

/// Picks the best installed voice for a language, preferring Personal Voice when enabled.
enum VoiceCatalog {
    static func voice(for language: String, allowPersonal: Bool) -> AVSpeechSynthesisVoice? {
        let prefix = String(language.prefix(2))
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(prefix) }

        if allowPersonal,
           AVSpeechSynthesizer.personalVoiceAuthorizationStatus == .authorized,
           let personal = voices.first(where: { $0.voiceTraits.contains(.isPersonalVoice) }) {
            return personal
        }
        let regular = voices.filter { !$0.voiceTraits.contains(.isPersonalVoice) && !$0.voiceTraits.contains(.isNoveltyVoice) }
        let exact = regular.filter { $0.language == language }
        let pool = exact.isEmpty ? regular : exact
        return pool.max(by: { $0.quality.rawValue < $1.quality.rawValue })
            ?? AVSpeechSynthesisVoice(language: language)
    }

    static func requestPersonalVoice() async -> Bool {
        await withCheckedContinuation { cont in
            AVSpeechSynthesizer.requestPersonalVoiceAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
    }
}
