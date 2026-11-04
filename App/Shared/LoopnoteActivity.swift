import ActivityKit
import Foundation
import SwiftUI

/// Live Activity shown on the Lock Screen and in the Dynamic Island.
struct LoopnoteActivityAttributes: ActivityAttributes {
    enum Kind: String, Codable, Hashable, Sendable {
        /// A meeting is being recorded; `date` is when recording started.
        case meeting
        /// The next note to speak; `date` is when it will speak.
        case nextNote
    }

    struct ContentState: Codable, Hashable, Sendable {
        var title: String
        var date: Date
        var paused: Bool = false
    }

    var kind: Kind
}

enum Brand {
    static let amber = Color(red: 1.0, green: 0.647, blue: 0.239)
}
