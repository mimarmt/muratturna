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
    private var places: [Note] { visible.filter { $0.hasLocation } }
    private var timed: [Note] { visible.filter { !$0.isAwaitingConfirmation && !$0.hasLocation } }
    private var today: [Note] {
        timed.filter { n in n.nextOccurrence().map { Calendar.current.isDateInToday($0) } ?? false }
    }
    private var later: [Note] {
        timed.filter { n in !(n.nextOccurrence().map { Calendar.current.isDateInToday($0) } ?? false) }
    }

    @AppStorage("home.guide.dismissed") private var guideDismissed = false

    var body: some View {
        List {
            if !guideDismissed || notes.isEmpty {
                HowItWorksCard { withAnimation { guideDismissed = true } }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            TipView(ControlCenterTip())
                .listRowSeparator(.hidden)
                .tint(Theme.amber)

            if !awaiting.isEmpty {
                Section {
                    ForEach(awaiting) { note in
                        HStack(spacing: 12) {
                            NoteRow(note: note)
                            Button { complete(note) } label: {
                                Label("Done", systemImage: "checkmark.circle")
                                    .labelStyle(.iconOnly)
                                    .font(.title2)
                                    .foregroundStyle(Theme.amber)
                            }
                            .buttonStyle(.borderless)
                        }
                        .modifier(RowActions(note: note, editing: $editing,
                                             complete: complete, delete: delete, snooze: nil, speak: speak))
                    }
                } header: {
                    SectionHeader(title: "Done?", subtitle: "Loopnote reminded you. Tap ✓ when it is finished.",
                                  symbol: "checkmark.circle", tint: Theme.amber)
                }
            }

            if !today.isEmpty {
                Section {
                    ForEach(today) { note in
                        NoteRow(note: note)
                            .modifier(RowActions(note: note, editing: $editing,
                                                 complete: complete, delete: delete, snooze: snooze, speak: speak))
                    }
                } header: {
                    SectionHeader(title: "Today", subtitle: nil, symbol: "sun.max", tint: .secondary)
                }
            }

            if !later.isEmpty {
                Section {
                    ForEach(later) { note in
                        NoteRow(note: note)
                            .modifier(RowActions(note: note, editing: $editing,
                                                 complete: complete, delete: delete, snooze: snooze, speak: speak))
                    }
                } header: {
                    SectionHeader(title: "Coming up", subtitle: nil, symbol: "calendar", tint: .secondary)
                }
            }

            if !places.isEmpty {
                Section {
                    ForEach(places) { note in
                        NoteRow(note: note)
                            .modifier(RowActions(note: note, editing: $editing,
                                                 complete: complete, delete: delete, snooze: nil, speak: speak))
                    }
                } header: {
                    SectionHeader(title: "At a place", subtitle: nil, symbol: "mappin.and.ellipse", tint: .secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .safeAreaInset(edge: .top, spacing: 0) {
            ProjectChips(projects: projects, selection: $projectFilter) { showProjects = true }
        }
        .overlay {
            if visible.isEmpty && !notes.isEmpty {
                ContentUnavailableView("No notes in this project", systemImage: "square.stack",
                                       description: Text("Choose “All” above or add a note to this project."))
            }
        }
        .navigationTitle("Loopnote")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { showArchive = true } label: {
                    Label("Archive", systemImage: "archivebox")
                }
                .accessibilityIdentifier("toolbar.archive")
                Button { showSettings = true } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .accessibilityIdentifier("toolbar.settings")
            }
        }
        .safeAreaInset(edge: .bottom) {
            GlassEffectContainer(spacing: 14) {
                HStack(spacing: 14) {
                    Button { compose(dictate: false) } label: {
                        ActionLabel(title: "Write", symbol: "square.and.pencil")
                    }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("action.write")

                    Button { compose(dictate: true) } label: {
                        ActionLabel(title: "Speak", symbol: "mic.fill", wide: true)
                    }
                    .buttonStyle(.glassProminent)
                    .popoverTip(SpeakTip(), arrowEdge: .bottom)
                    .accessibilityIdentifier("action.speak")

                    Button { AppRouter.shared.showMeetingRecorder = true } label: {
                        ActionLabel(title: "Meeting", symbol: "person.2.wave.2")
                    }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("action.meeting")
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
                .lineLimit(2)
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
                Label("Next: \(Self.when(wake)) (morning summary)", systemImage: "moon.fill")
                    .labelStyle(.titleAndIcon)
            } else if date.timeIntervalSince(context.date) < 60 {
                Text("Next: now")
            } else {
                Text("Next: \(Self.when(date)) (\(date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))))")
            }
        }
    }

    /// "14:30", "tomorrow 09:00" or "Fri 10:00".
    static func when(_ date: Date) -> String {
        let cal = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(date) { return time }
        if cal.isDateInTomorrow(date) { return String(localized: "tomorrow") + " " + time }
        return date.formatted(.dateTime.weekday(.abbreviated)) + " " + time
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

// MARK: - Home building blocks

/// Tap to edit, swipe for Done / Delete / Snooze, long-press to listen.
private struct RowActions: ViewModifier {
    let note: Note
    @Binding var editing: Note?
    let complete: (Note) -> Void
    let delete: (Note) -> Void
    let snooze: ((Note) -> Void)?
    let speak: (Note) -> Void

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture { editing = note }
            .swipeActions(edge: .leading) {
                Button { complete(note) } label: { Label("Done", systemImage: "checkmark") }
                    .tint(.green)
            }
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) { delete(note) } label: { Label("Delete", systemImage: "trash") }
                if let snooze {
                    Button { snooze(note) } label: { Label("Snooze 1 hour", systemImage: "clock") }
                        .tint(.gray)
                }
            }
            .contextMenu {
                Button { speak(note) } label: { Label("Listen", systemImage: "speaker.wave.2") }
                Button { editing = note } label: { Label("Edit", systemImage: "pencil") }
                Button { complete(note) } label: { Label("Done", systemImage: "checkmark") }
            }
    }
}

private struct SectionHeader: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey?
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
            if let subtitle {
                Text(subtitle).font(.caption).foregroundStyle(.secondary).textCase(nil)
            }
        }
        .textCase(nil)
    }
}

/// Horizontal project filter: All · projects · + Project.
private struct ProjectChips: View {
    let projects: [Project]
    @Binding var selection: UUID?
    var addProject: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: String(localized: "All"), color: nil, selected: selection == nil) { selection = nil }
                ForEach(projects) { p in
                    chip(title: p.name, color: Color(hex: p.colorHex), selected: selection == p.id,
                         muted: p.isMuted) { selection = selection == p.id ? nil : p.id }
                }
                Button(action: addProject) {
                    Label("Project", systemImage: "plus")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                }
                .buttonStyle(.glass)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
    }

    private func chip(title: String, color: Color?, selected: Bool, muted: Bool = false,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let color { Circle().fill(color).frame(width: 8, height: 8) }
                Text(title).lineLimit(1)
                if muted { Image(systemName: "speaker.slash").font(.caption2) }
            }
            .font(.subheadline.weight(selected ? .semibold : .regular))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .foregroundStyle(selected ? Color.black : Color.primary)
            .background(Capsule().fill(selected ? Theme.amber : Color.secondary.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Three-step explanation for new users; can be dismissed.
private struct HowItWorksCard: View {
    var dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("How Loopnote works").font(Theme.title(.headline))
                Spacer()
                Button(action: dismiss) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Close")
            }
            Step(number: 1, symbol: "mic.fill", text: "Speak or write what you must not forget.")
            Step(number: 2, symbol: "repeat", text: "Choose how often, or a place, to be reminded.")
            Step(number: 3, symbol: "speaker.wave.2.fill", text: "When it is time, the note says itself out loud.")
            Step(number: 4, symbol: "checkmark.circle", text: "When it is finished, tap Done. Until then it keeps reminding you.")
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 22).fill(Theme.amber.opacity(0.12)))
    }

    private struct Step: View {
        let number: Int
        let symbol: String
        let text: LocalizedStringKey
        var body: some View {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .frame(width: 26)
                    .foregroundStyle(Theme.amber)
                Text(text).font(.subheadline)
            }
        }
    }
}
