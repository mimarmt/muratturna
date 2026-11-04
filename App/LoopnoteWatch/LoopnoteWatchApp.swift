import Observation
import SwiftUI
import WatchConnectivity

@main
struct LoopnoteWatchApp: App {
    @State private var store = WatchStore()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                WatchNotesView()
            }
            .environment(store)
            .tint(Color(red: 1.0, green: 0.647, blue: 0.239))
        }
    }
}

/// Holds the latest notes from iPhone and sends actions back.
@MainActor
@Observable
final class WatchStore: NSObject, WCSessionDelegate {
    private(set) var notes: [WatchNote] = []
    private let cacheKey = "watch.notes"

    override init() {
        super.init()
        if let data = UserDefaults.standard.data(forKey: cacheKey),
           let cached = try? JSONDecoder().decode([WatchNote].self, from: data) {
            notes = cached
        }
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    func complete(_ note: WatchNote) {
        notes.removeAll { $0.id == note.id }
        send(.complete(note.id))
    }

    func add(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        send(.newNote(trimmed))
    }

    private func send(_ message: WatchMessage) {
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        // Queued delivery: arrives even if iPhone is locked or out of reach for a while.
        session.transferUserInfo(message.payload)
    }

    private func apply(_ data: Data) {
        guard let message = try? JSONDecoder().decode(WatchMessage.self, from: data),
              case .snapshot(let list) = message else { return }
        notes = list
        UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: cacheKey)
    }

    // MARK: WCSessionDelegate

    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState,
                             error: Error?) {
        guard let data = session.receivedApplicationContext[WatchMessage.key] as? Data else { return }
        Task { @MainActor in self.apply(data) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        guard let data = context[WatchMessage.key] as? Data else { return }
        Task { @MainActor in self.apply(data) }
    }
}

struct WatchNotesView: View {
    @Environment(WatchStore.self) private var store
    @State private var draft = ""
    @State private var composing = false

    var body: some View {
        List {
            if store.notes.isEmpty {
                Text("No living notes").foregroundStyle(.secondary)
            }
            ForEach(store.notes) { note in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        if note.isCritical { Image(systemName: "alarm").foregroundStyle(.tint) }
                        Text(note.title)
                            .font(.system(.headline, design: .serif))
                            .lineLimit(3)
                    }
                    if note.awaitingDone {
                        Text("Said · not done yet").font(.caption2).foregroundStyle(.tint)
                    } else if let next = note.next {
                        Text(next, style: .relative).font(.caption2).foregroundStyle(.secondary)
                    } else if !note.subtitle.isEmpty {
                        Text(note.subtitle).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .swipeActions {
                    Button { store.complete(note) } label: { Label("Done", systemImage: "checkmark") }
                        .tint(.green)
                }
            }
        }
        .navigationTitle("Loopnote")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { composing = true } label: { Image(systemName: "mic.fill") }
                    .accessibilityLabel("New note")
            }
        }
        .sheet(isPresented: $composing) {
            VStack(spacing: 10) {
                TextField("Say your note", text: $draft)
                Button("Save") {
                    store.add(draft)
                    draft = ""
                    composing = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
    }
}
