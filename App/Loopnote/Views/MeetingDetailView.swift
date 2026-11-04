import AVFoundation
import SwiftData
import SwiftUI
import TipKit
import UIKit
import LoopnoteCore

struct MeetingDetailView: View {
    @Bindable var meeting: Meeting
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @Query(sort: \Project.createdAt) private var projects: [Project]

    @State private var shareItem: ShareItem?
    @State private var player: AVAudioPlayer?
    @State private var isPlaying = false
    @State private var showTranscript = false

    struct ShareItem: Identifiable {
        let id = UUID()
        let items: [Any]
    }

    var body: some View {
        List {
            header
            statusSection
            if !meeting.summary.isBlank {
                Section("Summary") { Text(meeting.summary).textSelection(.enabled) }
            }
            if !meeting.decisions.isEmpty {
                Section("Decisions") {
                    ForEach(meeting.decisions, id: \.self) { d in
                        Label(d, systemImage: "checkmark.seal").labelStyle(BulletLabelStyle())
                    }
                }
            }
            if !meeting.actions.isEmpty { actionsSection }
            if !meeting.transcript.isBlank {
                Section {
                    DisclosureGroup("Transcript", isExpanded: $showTranscript) {
                        Text(meeting.transcript)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .navigationTitle(meeting.title.isEmpty ? String(localized: "Meeting") : meeting.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { shareMenu }
        }
        .sheet(item: $shareItem) { ShareSheet(items: $0.items) }
        .onDisappear { player?.stop() }
    }

    // MARK: Sections

    private var header: some View {
        Section {
            TextField("Title", text: $meeting.title, axis: .vertical)
                .font(Theme.title(.title2))
            HStack {
                Text(meeting.createdAt, format: .dateTime.weekday().day().month().hour().minute())
                Text("·")
                Text(MeetingExport.durationText(meeting))
                Spacer()
                if meeting.audioURL != nil {
                    Button { togglePlayback() } label: {
                        Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.title2).foregroundStyle(Theme.amber)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(isPlaying ? "Pause" : "Play recording")
                }
            }
            .font(.footnote).foregroundStyle(.secondary)
            Picker("Project", selection: Binding(get: { meeting.project?.id },
                                                 set: { id in meeting.project = projects.first { $0.id == id } })) {
                Text("None").tag(UUID?.none)
                ForEach(projects) { Text($0.name).tag(UUID?.some($0.id)) }
            }
        }
    }

    @ViewBuilder private var statusSection: some View {
        switch meeting.status {
        case .recorded, .transcribing, .summarizing:
            Section {
                ProgressRow(text: meeting.status == .summarizing ? "Finding decisions and action items…"
                                                                   : "Writing the transcript on your iPhone…")
                if !MeetingProcessor.shared.isProcessing(meeting.id) {
                    // Interrupted (app was closed): offer to continue.
                    Button("Continue processing") { MeetingProcessor.shared.retry(meeting) }
                        .foregroundStyle(Theme.amber)
                }
            } footer: {
                Text("You can leave the app. Processing continues and its progress appears on the Lock Screen.")
            }
        case .failed:
            Section {
                Label(meeting.errorMessage ?? String(localized: "Something went wrong."),
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                Button("Try again") { MeetingProcessor.shared.retry(meeting) }
            }
        case .ready:
            EmptyView()
        }
    }

    private var actionsSection: some View {
        Section {
            TipView(MeetingActionsTip()).tint(Theme.amber)
            ForEach(meeting.actions) { action in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: action.noteID == nil ? "circle" : "bell.badge.fill")
                        .foregroundStyle(Theme.amber)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(action.task)
                        let extra = [action.owner, action.due].filter { !$0.isBlank }
                        if !extra.isEmpty {
                            Text(extra.joined(separator: " · ")).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if action.noteID == nil {
                        Button("Remind") { makeReminder(action) }
                            .buttonStyle(.bordered)
                            .tint(Theme.amber)
                    } else {
                        Text("Reminding").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            if meeting.actions.contains(where: { $0.noteID == nil }) {
                Button {
                    meeting.actions.filter { $0.noteID == nil }.forEach(makeReminder)
                } label: {
                    Label("Remind me of all actions", systemImage: "bell.and.waves.left.and.right")
                }
            }
        } header: {
            Text("Action items")
        } footer: {
            Text("Each reminder speaks every morning until you mark it done. A due date in the action is used when Loopnote finds one.")
        }
    }

    private var shareMenu: some View {
        Menu {
            Button { if let u = MeetingExport.whatsAppURL(meeting) { openURL(u) } } label: {
                Label("Send via WhatsApp", systemImage: "message")
            }
            Button { if let u = MeetingExport.mailURL(meeting) { openURL(u) } } label: {
                Label("Send via Mail", systemImage: "envelope")
            }
            Button { if let u = MeetingExport.pdf(meeting) { shareItem = ShareItem(items: [u]) } } label: {
                Label("PDF minutes", systemImage: "doc.richtext")
            }
            Button { shareItem = ShareItem(items: [MeetingExport.text(meeting, bold: false)]) } label: {
                Label("Share…", systemImage: "square.and.arrow.up")
            }
            Button { UIPasteboard.general.string = MeetingExport.text(meeting, bold: false) } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
        .disabled(meeting.status != .ready)
        .accessibilityLabel("Share minutes")
    }

    // MARK: Actions

    private func makeReminder(_ action: MeetingAction) {
        let schedule: NoteSchedule
        let text = action.due.isBlank ? action.task : action.task + " " + action.due
        if let date = Self.detectDate(in: text) {
            var start = date
            let c = Calendar.current.dateComponents([.hour, .minute], from: date)
            if c.hour == 0 && c.minute == 0 || c.hour == 12 && c.minute == 0 {
                start = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: date) ?? date
            }
            schedule = start > .now ? NoteSchedule(start: start, rule: .once)
                                    : NoteSchedule(start: .now, rule: .daily(times: [TimeOfDay(hour: 9, minute: 0)]))
        } else {
            schedule = NoteSchedule(start: .now, rule: .daily(times: [TimeOfDay(hour: 9, minute: 0)]))
        }
        var details = action.task
        if !action.owner.isBlank { details += "\n" + String(localized: "Owner: \(action.owner)") }
        if !action.due.isBlank { details += "\n" + String(localized: "Due: \(action.due)") }
        details += "\n" + String(localized: "From meeting: \(meeting.title)")
        let note = Note(details: details, spokenTitle: action.task, schedule: schedule,
                        languageCode: LanguageDetector.speechLanguage(for: action.task),
                        project: meeting.project)
        context.insert(note)
        var actions = meeting.actions
        if let i = actions.firstIndex(where: { $0.id == action.id }) { actions[i].noteID = note.id }
        meeting.actions = actions
        try? context.save()
        Task { await AlertScheduler.shared.reschedule() }
    }

    static func detectDate(in text: String) -> Date? {
        guard let d = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        return d.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap(\.date).first
    }

    private func togglePlayback() {
        if isPlaying { player?.pause(); isPlaying = false; return }
        if player == nil, let url = meeting.audioURL {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try? AVAudioSession.sharedInstance().setActive(true)
            player = try? AVAudioPlayer(contentsOf: url)
        }
        player?.play()
        isPlaying = player?.isPlaying ?? false
    }
}

private struct ProgressRow: View {
    let text: LocalizedStringKey
    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text(text).foregroundStyle(.secondary)
        }
    }
}

private struct BulletLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .top, spacing: 10) {
            configuration.icon.foregroundStyle(Theme.amber)
            configuration.title
        }
    }
}

/// UIKit share sheet (used for the PDF file).
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
