import SwiftData
import SwiftUI

struct ArchiveView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<Note> { $0.completedAt != nil },
           sort: \Note.completedAt, order: .reverse) private var notes: [Note]

    var body: some View {
        List {
            ForEach(notes) { note in
                VStack(alignment: .leading, spacing: 4) {
                    Text(note.textToSpeak).font(Theme.title(.body))
                    if let done = note.completedAt {
                        Text(done, format: .dateTime.day().month().year().hour().minute())
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .swipeActions(edge: .leading) {
                    Button {
                        note.completedAt = nil
                        commit()
                    } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
                    .tint(Theme.amber)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        context.delete(note)
                        commit()
                    } label: { Label("Delete", systemImage: "trash") }
                }
            }
        }
        .overlay {
            if notes.isEmpty {
                ContentUnavailableView("Archive is empty", systemImage: "archivebox",
                                       description: Text("Completed and finished notes appear here."))
            }
        }
        .navigationTitle("Archive")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }

    private func commit() {
        try? context.save()
        Task { await AlertScheduler.shared.reschedule() }
    }
}
