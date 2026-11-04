import SwiftUI
import TipKit

/// Short, one-time hints that teach Loopnote's less obvious features.
struct SpeakTip: Tip {
    var title: Text { Text("Just say it") }
    var message: Text? { Text("Speak a note. Loopnote writes a short spoken title and reads it aloud when it is time.") }
    var image: Image? { Image(systemName: "waveform") }
}

struct ControlCenterTip: Tip {
    static let createdNote = Tips.Event(id: "createdNote")

    var title: Text { Text("Start from anywhere") }
    var message: Text? {
        Text("Add “Voice note” or “Record meeting” to Control Center, the Lock Screen or the Action button.")
    }
    var image: Image? { Image(systemName: "switch.2") }
    var rules: [Rule] {
        #Rule(Self.createdNote) { $0.donations.count >= 2 }
    }
}

struct MeetingActionsTip: Tip {
    var title: Text { Text("Never drop an action") }
    var message: Text? { Text("Tap Remind and the action speaks every morning until you mark it done.") }
    var image: Image? { Image(systemName: "bell.and.waves.left.and.right") }
}
