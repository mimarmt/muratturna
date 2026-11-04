import Foundation
import MetricKit

/// Collects crash and hang reports (MetricKit) on device so they can be shared from Settings.
final class Diagnostics: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = Diagnostics()

    static var directory: URL {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func start() {
        MXMetricManager.shared.add(self)
    }

    static var reports: [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    static func clear() {
        for url in reports { try? FileManager.default.removeItem(at: url) }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            let stamp = Int(Date.now.timeIntervalSince1970)
            let url = Self.directory.appendingPathComponent("diagnostic-\(stamp)-\(UUID().uuidString.prefix(6)).json")
            try? payload.jsonRepresentation().write(to: url)
        }
    }
}
