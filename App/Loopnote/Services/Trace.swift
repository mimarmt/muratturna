import Foundation

/// A small on-device step log ("breadcrumbs") plus a main-thread watchdog.
///
/// Each important step writes one line. If the main thread stops responding for more than
/// two seconds, the watchdog writes which step came last, so a freeze can be located from
/// Settings after the app is reopened. Nothing leaves the device unless the user shares it.
enum Trace {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var lines: [String] = load()
    nonisolated(unsafe) private static var lastStep = "launch"
    private static let maxLines = 300

    static var fileURL: URL { Diagnostics.directory.appendingPathComponent("trace.log") }

    /// Records one step. Safe from any thread.
    nonisolated static func log(_ step: String) {
        let stamp = Date.now.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute().second())
        let thread = Thread.isMainThread ? "main" : "bg"
        lock.lock()
        lastStep = step
        lines.append("\(stamp) [\(thread)] \(step)")
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        let text = lines.joined(separator: "\n")
        lock.unlock()
        try? text.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    nonisolated static var recent: [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(lines.suffix(40).reversed())
    }

    nonisolated static func clear() {
        lock.lock(); lines = []; lock.unlock()
        try? FileManager.default.removeItem(at: fileURL)
    }

    private static func load() -> [String] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    // MARK: Watchdog

    nonisolated(unsafe) private static var started = false

    /// Starts a background thread that notices when the main thread is blocked.
    static func startWatchdog() {
        guard !started else { return }
        started = true
        let thread = Thread {
            var reported = false
            while true {
                let answered = Flag()
                DispatchQueue.main.async { answered.set() }
                Thread.sleep(forTimeInterval: 2)
                if answered.value {
                    if reported { log("main thread responsive again") }
                    reported = false
                } else if !reported {
                    reported = true
                    lock.lock(); let step = lastStep; lock.unlock()
                    log("MAIN THREAD BLOCKED (>2s). Last step: \(step)")
                }
            }
        }
        thread.name = "loopnote.watchdog"
        thread.qualityOfService = .utility
        thread.start()
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var on = false
        func set() { lock.lock(); on = true; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return on }
    }
}
