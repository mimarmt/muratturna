import SwiftData
import SwiftUI
import TipKit

struct NotesListView: View {
    @Environment(\.modelContext) private var context
    @Query(filter: #Predicate<Note> { $0.completedAt == nil }) private var notes: [Note]
    @Query(sort: \Project.createdAt) private var projects: [Project]

    @State private var editing: Note?
    @State private var composer: Composer?
    @State private var projectFilter: UUID?
    @State private var showSettings = false
    @State private var showArchive = false
    @State private var showProjects = false

    struct Composer: Identifiable {
        let id = UUID()
        let dictate: Bool
    }

    private var visible: [Note] {
        notes
            .filter { projectFilter == nil || $0.project?.id == projectFilter }
            .sorted { ($0.nextOccurrence() ?? .distantFuture) < ($1.nextOccurrence() ?? .distantFuture) }
    }

    /// Spoke already, schedule ran out, not marked done yet.
    private var awaiting: [Note] { visible.filter(\.isAwaitingConfirmation) }
    private var upcoming: [Note] { visible.filter { !$0.isAwaitingConfirmation } }

    var body: some View {
        List {
            TipView(ControlCenterTip())
                .listRowSeparator(.hidden)
                .tint(Theme.amber)
            if !awaiting.isEmpty {
                Section {
                    ForEach(awaiting) { note in
                        HStack(spacing: 12) {
                            NoteRow(note: note)
                            Button { complete(note) } label: {
                                Image(systemName: "checkmark.circle")
                                    .font(.title2)
                                    .foregroundStyle(Theme.amber)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Done")
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { editing = note }
                        .swipeActions(edge: .leading) {
                            Button { complete(note) } label: { Label("Done", systemImage: "checkmark") }
                                .tint(.green)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { delete(note) } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                } header: {
                    Label("Said · not done yet", systemImage: "checkmark.bubble")
                        .foregroundStyle(Theme.amber)
                }
            }
            ForEach(upcoming) { note in
                NoteRow(note: note)
                    .contentShape(Rectangle())
                    .onTapGesture { editing = note }
                    .swipeActions(edge: .leading) {
                        Button { complete(note) } label: { Label("Done", systemImage: "checkmark") }
                            .tint(.green)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { delete(note) } label: { Label("Delete", systemImage: "trash") }
                        Button { snooze(note) } label: { Label("Snooze 1 hour", systemImage: "clock") }
                            .tint(.gray)
                    }
                    .contextMenu {
                        Button { speak(note) } label: { Label("Listen", systemImage: "speaker.wave.2") }
                        Button { complete(note) } label: { Label("Done", systemImage: "checkmark") }
                    }
            }
        }
        .listStyle(.plain)
        .overlay {
            if visible.isEmpty {
                ContentUnavailableView {
                    Label("No living notes yet", systemImage: "waveform")
                } description: {
                    Text("Tap Speak and say what you must not forget.")
                }
            }
        }
        .navigationTitle("Loopnote")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Picker("Project", selection: $projectFilter) {
                        Text("All notes").tag(UUID?.none)
                        ForEach(projects) { p in
                            Label(p.name, systemImage: p.isMuted ? "speaker.slash" : "circle.fill")
                                .tag(UUID?.some(p.id))
                        }
                    }
                } label: {
                    Image(systemName: projectFilter == nil
                          ? "line.3.horizontal.decrease.circle"
                          : "line.3.horizontal.decrease.circle.fill")
                }
                .accessibilityLabel("Filter by project")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showProjects = true } label: { Label("Projects", systemImage: "square.stack") }
                    Button { showArchive = true } label: { Label("Archive", systemImage: "archivebox") }
                    Button { showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More")
            }
        }
        .safeAreaInset(edge: .bottom) {
            GlassEffectContainer(spacing: 14) {
                HStack(spacing: 14) {
                    Button { compose(dictate: false) } label: {
                        ActionLabel(title: "Write", symbol: "square.and.pencil")
                    }
                    .buttonStyle(.glass)

                    Button { compose(dictate: true) } label: {
                        ActionLabel(title: "Speak", symbol: "mic.fill", wide: true)
                    }
                    .buttonStyle(.glassProminent)
                    .popoverTip(SpeakTip(), arrowEdge: .bottom)

                    Button { AppRouter.shared.showMeetingRecorder = true } label: {
                        ActionLabel(title: "Meeting", symbol: "person.2.wave.2")
                    }
                    .buttonStyle(.glass)
                }
            }
            .padding(.bottom, 8)
        }
        .onChange(of: AppRouter.shared.startVoiceNote, initial: true) { _, start in
            if start {
                AppRouter.shared.startVoiceNote = false
                composer = Composer(dictate: true)
            }
        }
        .sheet(item: $editing) { NoteEditorView(note: $0) }
        .sheet(item: $composer) { NoteEditorView(note: nil, startDictation: $0.dictate, project: selectedProject) }
        .sheet(isPresented: $showSettings) { NavigationStack { SettingsView() } }
        .sheet(isPresented: $showArchive) { NavigationStack { ArchiveView() } }
        .sheet(isPresented: $showProjects) { NavigationStack { ProjectsView() } }
    }

    private var selectedProject: Project? {
        projects.first { $0.id == projectFilter }
    }

    /// Free plan: up to 10 active notes.
    private func compose(dictate: Bool) {
        if notes.count >= ProStore.freeNoteLimit, !ProStore.shared.require() { return }
        composer = Composer(dictate: dictate)
    }

    private func complete(_ note: Note) {
        withAnimation { note.completedAt = .now }
        commit()
    }

    private func snooze(_ note: Note) {
        note.snoozedUntil = .now.addingTimeInterval(3_600)
        commit()
    }

    private func delete(_ note: Note) {
        PhotoStore.delete(note.photoFileName)
        withAnimation { context.delete(note) }
        commit()
    }

    private func speak(_ note: Note) {
        SpeechRenderer.shared.speakNow(note.textToSpeak,
                                       language: note.languageCode ?? LanguageDetector.fallback)
    }

    private func commit() {
        try? context.save()
        Task { await AlertScheduler.shared.reschedule() }
    }
}

struct NoteRow: View {
    let note: Note

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Rectangle()
                .fill(note.project.map { Color(hex: $0.colorHex) } ?? Color.secondary.opacity(0.25))
                .frame(width: 2)
                .opacity(note.project?.isMuted == true ? 0.3 : 1)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(note.textToSpeak)
                        .font(Theme.title())
                        .lineLimit(2)
                    if note.isCritical {
                        Image(systemName: "bell.badge.fill")
                            .foregroundStyle(Theme.amber)
                            .font(.footnote)
                            .accessibilityLabel("Critical")
                    }
                }
                HStack(spacing: 6) {
                    if note.hasLocation {
                        Image(systemName: "mappin.and.ellipse")
                        Text(note.locationName ?? String(localized: "Chosen place"))
                        Text("·")
                        Text(note.locationOnArrive ? "on arrival" : "on leaving")
                    } else {
                        Image(systemName: "repeat")
                        Text(ScheduleText.rule(note.schedule.rule))
                    }
                    if note.hasLocation {
                        EmptyView()
                    } else if let next = note.nextOccurrence() {
                        Text("·")
                        NextTimeLabel(date: next)
                    } else {
                        Text("·")
                        Text("Mark it done when finished")
                    }
                    if note.project?.isMuted == true {
                        Image(systemName: "speaker.slash")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            if let name = note.photoFileName, let image = PhotoStore.thumbnail(name) {
                Spacer(minLength: 0)
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel("Photo")
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

/// "in 12 min" / "🌙 07:30" — refreshes every 30 seconds instead of ticking seconds.
struct NextTimeLabel: View {
    let date: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let quiet = AppSettings.quietHours
            if quiet.contains(date, calendar: .current) {
                let wake = quiet.windowEnd(after: date, calendar: .current)
                Label(wake.formatted(date: .omitted, time: .shortened), systemImage: "moon.fill")
                    .labelStyle(.titleAndIcon)
            } else if date.timeIntervalSince(context.date) < 60 {
                Text("now")
            } else {
                Text(date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))
            }
        }
    }
}

/// Icon-over-caption label for the bottom action bar; never wraps.
struct ActionLabel: View {
    let title: LocalizedStringKey
    let symbol: String
    var wide = false

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(wide ? .title2.weight(.semibold) : .title3)
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(width: wide ? 112 : 76, height: 52)
    }
}
