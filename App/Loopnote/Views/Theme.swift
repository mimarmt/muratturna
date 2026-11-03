import SwiftUI
import UIKit
import LoopnoteCore

/// Design tokens: architectural minimalism, monochrome with a single warm amber accent.
enum Theme {
    static let amber = Color("AccentColor")

    static let projectPalette = ["#FFA53D", "#8E8E93", "#5E8C6A", "#4A6FA5", "#B5534C", "#9B7BB8", "#C8A96A"]

    static func title(_ style: Font.TextStyle = .title3) -> Font {
        .system(style, design: .serif).weight(.semibold)
    }

    static func applyNavigationBarAppearance() {
        func serif(_ size: CGFloat, _ weight: UIFont.Weight) -> UIFont {
            let base = UIFont.systemFont(ofSize: size, weight: weight)
            guard let d = base.fontDescriptor.withDesign(.serif) else { return base }
            return UIFont(descriptor: d, size: size)
        }
        UINavigationBar.appearance().largeTitleTextAttributes = [.font: serif(34, .bold)]
        UINavigationBar.appearance().titleTextAttributes = [.font: serif(17, .semibold)]
    }
}

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self.init(red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255)
    }
}

/// Human-readable, localized descriptions of schedules.
enum ScheduleText {
    static func rule(_ rule: RepeatRule) -> String {
        switch rule {
        case .once:
            return String(localized: "Once")
        case .interval(let m):
            if m % 10_080 == 0 { return m == 10_080 ? String(localized: "Every week") : String(localized: "Every \(m / 10_080) weeks") }
            if m % 1_440 == 0 { return m == 1_440 ? String(localized: "Every day") : String(localized: "Every \(m / 1_440) days") }
            if m % 60 == 0 { return m == 60 ? String(localized: "Every hour") : String(localized: "Every \(m / 60) hours") }
            return String(localized: "Every \(m) min")
        case .daily(let times):
            return String(localized: "Daily") + " " + times.sorted().map(time).joined(separator: ", ")
        case .weekly(let days, let times):
            let symbols = Calendar.current.shortWeekdaySymbols
            let names = days.sorted().map { symbols[$0 - 1] }.joined(separator: ", ")
            return names + " " + times.sorted().map(time).joined(separator: ", ")
        }
    }

    static func time(_ t: TimeOfDay) -> String {
        t.on(.now, calendar: .current).formatted(date: .omitted, time: .shortened)
    }
}
