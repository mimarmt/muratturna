import Foundation
import UIKit

/// Formats meeting minutes for WhatsApp, Mail and PDF.
@MainActor
enum MeetingExport {
    static func dateText(_ m: Meeting) -> String {
        m.createdAt.formatted(date: .long, time: .shortened)
    }

    static func durationText(_ m: Meeting) -> String {
        let units: Set<Duration.UnitsFormatStyle.Unit> = m.duration < 60 ? [.seconds] : [.hours, .minutes]
        return Duration.seconds(m.duration.rounded()).formatted(.units(allowed: units, width: .abbreviated))
    }

    /// Plain text with WhatsApp-friendly *bold* headings.
    static func text(_ m: Meeting, bold: Bool = true) -> String {
        func h(_ s: String) -> String { bold ? "*\(s)*" : s.uppercased() }
        var out = [h(m.title.isEmpty ? String(localized: "Meeting") : m.title),
                   "\(dateText(m)) · \(durationText(m))"]
        if let p = m.project { out.append(String(localized: "Project: \(p.name)")) }
        if !m.summary.isBlank {
            out += ["", h(String(localized: "Summary")), m.summary]
        }
        if !m.decisions.isEmpty {
            out += ["", h(String(localized: "Decisions"))] + m.decisions.map { "• " + $0 }
        }
        if !m.actions.isEmpty {
            out += ["", h(String(localized: "Action items"))]
            out += m.actions.map { a in
                var line = "☐ " + a.task
                let extra = [a.owner, a.due].filter { !$0.isBlank }
                if !extra.isEmpty { line += " — " + extra.joined(separator: ", ") }
                return line
            }
        }
        out += ["", String(localized: "Created with Loopnote")]
        return out.joined(separator: "\n")
    }

    static func whatsAppURL(_ m: Meeting) -> URL? {
        var c = URLComponents(string: "https://wa.me/")
        c?.queryItems = [URLQueryItem(name: "text", value: text(m))]
        return c?.url
    }

    static func mailURL(_ m: Meeting) -> URL? {
        var c = URLComponents()
        c.scheme = "mailto"
        c.queryItems = [URLQueryItem(name: "subject", value: m.title.isEmpty ? String(localized: "Meeting") : m.title),
                        URLQueryItem(name: "body", value: text(m, bold: false))]
        return c.url
    }

    /// Multi-page A4 PDF minutes.
    static func pdf(_ m: Meeting) -> URL? {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\n", with: "<br>")
        }
        var html = """
        <html><head><meta charset="utf-8"><style>
        body { font-family: -apple-system, Helvetica; font-size: 11pt; color: #1c1c1e; }
        h1 { font-family: 'New York', Georgia, serif; font-size: 22pt; margin: 0 0 4pt 0; }
        h2 { font-family: 'New York', Georgia, serif; font-size: 13pt; margin: 18pt 0 6pt 0;
             border-bottom: 0.5pt solid #c7c7cc; padding-bottom: 3pt; }
        .meta { color: #6e6e73; font-size: 10pt; }
        .accent { color: #E8892A; }
        li { margin-bottom: 4pt; }
        .transcript { font-size: 9.5pt; color: #3a3a3c; line-height: 1.45; }
        </style></head><body>
        <div class="accent meta">LOOPNOTE · \(esc(String(localized: "MEETING MINUTES")))</div>
        <h1>\(esc(m.title.isEmpty ? String(localized: "Meeting") : m.title))</h1>
        <div class="meta">\(esc(dateText(m))) · \(esc(durationText(m)))\(m.project.map { " · " + esc($0.name) } ?? "")</div>
        """
        if !m.summary.isBlank {
            html += "<h2>\(esc(String(localized: "Summary")))</h2><p>\(esc(m.summary))</p>"
        }
        if !m.decisions.isEmpty {
            html += "<h2>\(esc(String(localized: "Decisions")))</h2><ul>"
                + m.decisions.map { "<li>\(esc($0))</li>" }.joined() + "</ul>"
        }
        if !m.actions.isEmpty {
            html += "<h2>\(esc(String(localized: "Action items")))</h2><ul>"
                + m.actions.map { a in
                    let extra = [a.owner, a.due].filter { !$0.isBlank }.joined(separator: ", ")
                    return "<li>☐ \(esc(a.task))\(extra.isEmpty ? "" : " <span class='meta'>— \(esc(extra))</span>")</li>"
                }.joined() + "</ul>"
        }
        if !m.transcript.isBlank {
            html += "<h2>\(esc(String(localized: "Transcript")))</h2><div class='transcript'>\(esc(m.transcript))</div>"
        }
        html += "</body></html>"

        let formatter = UIMarkupTextPrintFormatter(markupText: html)
        let renderer = UIPrintPageRenderer()
        renderer.addPrintFormatter(formatter, startingAtPageAt: 0)
        let page = CGRect(x: 0, y: 0, width: 595.2, height: 841.8)        // A4 in points
        let printable = page.insetBy(dx: 48, dy: 56)
        renderer.setValue(page, forKey: "paperRect")
        renderer.setValue(printable, forKey: "printableRect")

        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, page, nil)
        for i in 0..<renderer.numberOfPages {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: i, in: UIGraphicsGetPDFContextBounds())
        }
        UIGraphicsEndPDFContext()

        let safe = (m.title.isEmpty ? "Meeting" : m.title)
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?*\"<>|")).joined(separator: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safe).pdf")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}
