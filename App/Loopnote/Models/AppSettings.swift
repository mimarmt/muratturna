import Foundation
import LoopnoteCore

/// User preferences stored in UserDefaults (per device).
enum AppSettings {
    private static var d: UserDefaults { .standard }

    enum Key {
        static let quietEnabled = "quiet.enabled"
        static let quietStart = "quiet.start"     // minutes since midnight
        static let quietEnd = "quiet.end"
        static let usePersonalVoice = "voice.personal"
        static let speechRate = "voice.rate"
        static let onboarded = "onboarded"
        static let elevenEnabled = "eleven.enabled"
        static let elevenVoiceID = "eleven.voice.id"
        static let elevenVoiceName = "eleven.voice.name"
        static let elevenModel = "eleven.model"
    }

    static func registerDefaults() {
        d.register(defaults: [
            Key.quietEnabled: true,
            Key.quietStart: 23 * 60,
            Key.quietEnd: 7 * 60 + 30,
            Key.usePersonalVoice: false,
            Key.speechRate: 0.5
        ])
    }

    static var quietHours: QuietHours {
        let s = d.integer(forKey: Key.quietStart), e = d.integer(forKey: Key.quietEnd)
        return QuietHours(start: TimeOfDay(hour: s / 60, minute: s % 60),
                          end: TimeOfDay(hour: e / 60, minute: e % 60),
                          isEnabled: d.bool(forKey: Key.quietEnabled))
    }

    static var usePersonalVoice: Bool { d.bool(forKey: Key.usePersonalVoice) }

    /// ElevenLabs voice to use, when enabled and configured.
    static var elevenVoice: (id: String, model: String)? {
        guard d.bool(forKey: Key.elevenEnabled),
              let id = d.string(forKey: Key.elevenVoiceID), !id.isEmpty,
              ElevenLabsClient.apiKey != nil else { return nil }
        let model = d.string(forKey: Key.elevenModel) ?? ElevenLabsClient.Model.multilingualV2.rawValue
        return (id, model)
    }

    static func voiceKey(for language: String) -> String { "voice.id." + language.prefix(2) }
    static func voiceIdentifier(for language: String) -> String? {
        let v = d.string(forKey: voiceKey(for: language))
        return (v?.isEmpty ?? true) ? nil : v
    }
    static var speechRate: Float { Float(d.double(forKey: Key.speechRate)) }
}
