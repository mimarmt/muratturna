import SwiftData
import SwiftUI

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

    var body: some View {
        List {
            ForEach(visible) { note in
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
            GlassEffectContainer(spacing: 16) {
                HStack(spacing: 16) {
                    Button { composer = Composer(dictate: false) } label: {
                        Label("Write", systemImage: "square.and.pencil")
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.glass)

                    Button { composer = Composer(dictate: true) } label: {
                        Label("Speak", systemImage: "mic.fill")
                            .font(.headline)
                            .padding(.horizontal, 18)
                    }
                    .buttonStyle(.glassProminent)
                }
                .controlSize(.extraLarge)
            }
            .padding(.bottom, 8)
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

    private func complete(_ note: Note) {
        withAnimation { note.completedAt = .now }
        commit()
    }

    private func snooze(_ note: Note) {
        note.snoozedUntil = .now.addingTimeInterval(3_600)
        commit()
    }

    private func delete(_ note: Note) {
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
                    Image(systemName: "repeat")
                    Text(ScheduleText.rule(note.schedule.rule))
                    if let next = note.nextOccurrence() {
                        Text("·")
                        Text(next, style: .relative)
                            .monospacedDigit()
                    }
                    if note.project?.isMuted == true {
                        Image(systemName: "speaker.slash")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}
