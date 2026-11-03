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
    static var speechRate: Float { Float(d.double(forKey: Key.speechRate)) }
}
