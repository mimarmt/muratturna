import SwiftUI
import WidgetKit

/// Home Screen and Lock Screen widget: the notes that speak next.
struct NotesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SharedNotes.widgetKind, provider: NotesProvider()) { entry in
            NotesWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Next notes")
        .description("The notes Loopnote will read to you next.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge,
                            .accessoryRectangular, .accessoryInline])
    }
}

struct NotesEntry: TimelineEntry {
    let date: Date
    let notes: [WatchNote]

    /// Notes still to speak after this entry's moment, soonest first; finished ones go last.
    var upcoming: [WatchNote] {
        notes.sorted { a, b in
            let da = a.next.flatMap { $0 >= date ? $0 : nil } ?? .distantFuture
            let db = b.next.flatMap { $0 >= date ? $0 : nil } ?? .distantFuture
            return da < db
        }
    }
}

struct NotesProvider: TimelineProvider {
    func placeholder(in context: Context) -> NotesEntry {
        NotesEntry(date: .now, notes: [
            WatchNote(id: UUID(), title: String(localized: "Call the municipality about the permit"),
                      subtitle: "Yalova", next: .now.addingTimeInterval(1800),
                      isCritical: false, awaitingDone: false),
            WatchNote(id: UUID(), title: String(localized: "Send the facade renders"),
                      subtitle: "", next: .now.addingTimeInterval(7200),
                      isCritical: false, awaitingDone: false)
        ])
    }

    func getSnapshot(in context: Context, completion: @escaping (NotesEntry) -> Void) {
        let notes = SharedNotes.load()
        completion(notes.isEmpty ? placeholder(in: context) : NotesEntry(date: .now, notes: notes))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NotesEntry>) -> Void) {
        let notes = SharedNotes.load()
        // One entry now and one right after each upcoming reminder, so the list moves on by itself.
        let moments = notes.compactMap(\.next).filter { $0 > .now }.sorted().prefix(12)
        let entries = [NotesEntry(date: .now, notes: notes)]
            + moments.map { NotesEntry(date: $0.addingTimeInterval(1), notes: notes) }
        completion(Timeline(entries: entries, policy: .after(.now.addingTimeInterval(6 * 3600))))
    }
}

struct NotesWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NotesEntry

    var body: some View {
        switch family {
        case .accessoryInline:
            if let first = entry.upcoming.first {
                Label(first.title, systemImage: "waveform")
            } else {
                Label("No notes", systemImage: "waveform")
            }
        case .accessoryRectangular:
            if let first = entry.upcoming.first {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Loopnote", systemImage: "waveform").font(.caption2.weight(.semibold))
                    Text(first.title).font(.headline).lineLimit(2)
                    if let next = first.next, next > entry.date {
                        Text(next, style: .relative).font(.caption2)
                    }
                }
            } else {
                Label("No notes", systemImage: "waveform")
            }
        default:
            list
        }
    }

    private var rows: Int {
        switch family {
        case .systemSmall: 2
        case .systemLarge: 7
        default: 3
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "waveform").foregroundStyle(Brand.amber)
                Text("Next notes").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
            }
            if entry.notes.isEmpty {
                Spacer()
                Text("Add a note in Loopnote and it will appear here.")
                    .font(.footnote).foregroundStyle(.secondary)
                Spacer()
            } else {
                ForEach(entry.upcoming.prefix(rows)) { note in
                    NoteLine(note: note, now: entry.date, compact: family == .systemSmall)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

private struct NoteLine: View {
    let note: WatchNote
    let now: Date
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if note.isCritical {
                    Image(systemName: "bell.badge.fill").font(.caption2).foregroundStyle(Brand.amber)
                }
                Text(note.title)
                    .font(.system(compact ? .footnote : .subheadline, design: .serif).weight(.semibold))
                    .lineLimit(compact ? 2 : 1)
            }
            Group {
                if note.awaitingDone {
                    Text("Done?")
                } else if let next = note.next, next > now {
                    Text(next, style: .relative)
                } else if !note.subtitle.isEmpty {
                    Text(note.subtitle)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }
}
