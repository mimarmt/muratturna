import SwiftData
import SwiftUI

struct MeetingsListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Meeting.createdAt, order: .reverse) private var meetings: [Meeting]
    @State private var path: [UUID] = []

    var body: some View {
        List {
            ForEach(meetings) { m in
                NavigationLink(value: m.id) { MeetingRow(meeting: m) }
            }
            .onDelete { offsets in
                for i in offsets {
                    if let url = meetings[i].audioURL { try? FileManager.default.removeItem(at: url) }
                    context.delete(meetings[i])
                }
                try? context.save()
            }
        }
        .listStyle(.plain)
        .overlay {
            if meetings.isEmpty {
                ContentUnavailableView {
                    Label("No meetings yet", systemImage: "person.2.wave.2")
                } description: {
                    Text("Record a meeting. Loopnote writes the minutes and turns actions into reminders.")
                } actions: {
                    Button("Start recording") { AppRouter.shared.showMeetingRecorder = true }
                        .buttonStyle(.glassProminent)
                }
            }
        }
        .navigationTitle("Meetings")
        .navigationDestination(for: UUID.self) { id in
            if let m = meetings.first(where: { $0.id == id }) { MeetingDetailView(meeting: m) }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { AppRouter.shared.showMeetingRecorder = true } label: {
                    Image(systemName: "record.circle")
                }
                .accessibilityLabel("Start recording")
            }
        }
        .onChange(of: AppRouter.shared.openMeetingID, initial: true) { _, id in
            if let id {
                AppRouter.shared.openMeetingID = nil
                path = [id]
            }
        }
        .modifier(PathBinding(path: $path))
    }
}

/// Lets the list drive its parent NavigationStack without owning it.
private struct PathBinding: ViewModifier {
    @Binding var path: [UUID]
    func body(content: Content) -> some View {
        content.navigationDestination(isPresented: Binding(get: { !path.isEmpty }, set: { if !$0 { path = [] } })) {
            if let id = path.first { MeetingDetailLoader(id: id) }
        }
    }
}

private struct MeetingDetailLoader: View {
    let id: UUID
    @Query private var meetings: [Meeting]
    init(id: UUID) {
        self.id = id
        _meetings = Query(filter: #Predicate<Meeting> { $0.id == id })
    }
    var body: some View {
        if let m = meetings.first { MeetingDetailView(meeting: m) } else { ProgressView() }
    }
}

struct MeetingRow: View {
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(meeting.title.isEmpty ? String(localized: "Meeting") : meeting.title)
                .font(Theme.title())
                .lineLimit(2)
            HStack(spacing: 6) {
                Text(meeting.createdAt, format: .dateTime.day().month().hour().minute())
                Text("·")
                Text(MeetingExport.durationText(meeting))
                Spacer()
                MeetingStatusBadge(status: meeting.status, actions: meeting.actions.count)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }
}

struct MeetingStatusBadge: View {
    let status: Meeting.Status
    let actions: Int

    var body: some View {
        switch status {
        case .recorded, .transcribing:
            Label("Transcribing", systemImage: "waveform").symbolEffect(.variableColor.iterative)
        case .summarizing:
            Label("Summarizing", systemImage: "sparkles").symbolEffect(.pulse)
        case .ready:
            if actions > 0 { Label("\(actions) actions", systemImage: "checklist").foregroundStyle(Theme.amber) }
        case .failed:
            Label("Failed", systemImage: "exclamationmark.triangle").foregroundStyle(.red)
        }
    }
}
