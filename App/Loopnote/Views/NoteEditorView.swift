import SwiftData
import SwiftUI
import LoopnoteCore

struct NoteEditorView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Project.createdAt) private var projects: [Project]

    let note: Note?
    let startDictation: Bool

    @State private var details: String
    @State private var spokenTitle: String
    @State private var isCritical: Bool
    @State private var projectID: UUID?

    @State private var mode: RepeatMode
    @State private var intervalValue: Int
    @State private var intervalUnit: IntervalUnit
    @State private var times: [Date]
    @State private var weekdays: Set<Int>
    @State private var start: Date

    @State private var endMode: EndMode
    @State private var untilDate: Date
    @State private var count: Int

    @State private var dictation = DictationService()
    @State private var isGeneratingTitle = false
    @State private var isSaving = false
    @FocusState private var textFocused: Bool

    enum RepeatMode: String, CaseIterable, Identifiable {
        case once, interval, daily, weekly
        var id: Self { self }
        var label: LocalizedStringKey {
            switch self {
            case .once: "Once"
            case .interval: "Every…"
            case .daily: "Daily"
            case .weekly: "Weekly"
            }
        }
    }

    enum IntervalUnit: Int, CaseIterable, Identifiable {
        case minutes = 1, hours = 60, days = 1_440, weeks = 10_080
        var id: Int { rawValue }
        var label: LocalizedStringKey {
            switch self {
            case .minutes: "minutes"
            case .hours: "hours"
            case .days: "days"
            case .weeks: "weeks"
            }
        }
    }

    enum EndMode: String, CaseIterable, Identifiable {
        case never, until, count
        var id: Self { self }
        var label: LocalizedStringKey {
            switch self {
            case .never: "Never"
            case .until: "On date"
            case .count: "After"
            }
        }
    }

    init(note: Note?, startDictation: Bool = false, project: Project? = nil) {
        self.note = note
        self.startDictation = startDictation
        let schedule = note?.schedule ?? NoteSchedule(start: .now.addingTimeInterval(600), rule: .everyHours(1))
        _details = State(initialValue: note?.details ?? "")
        _spokenTitle = State(initialValue: note?.spokenTitle ?? "")
        _isCritical = State(initialValue: note?.isCritical ?? false)
        _projectID = State(initialValue: note?.project?.id ?? project?.id)
        _start = State(initialValue: schedule.start)

        var mode = RepeatMode.interval, value = 1, unit = IntervalUnit.hours
        var times = [schedule.start], weekdays: Set<Int> = [Calendar.current.component(.weekday, from: .now)]
        func dates(_ t: [TimeOfDay]) -> [Date] { t.sorted().map { $0.on(.now, calendar: .current) } }
        switch schedule.rule {
        case .once: mode = .once
        case .interval(let m):
            mode = .interval
            unit = IntervalUnit.allCases.reversed().first { m % $0.rawValue == 0 } ?? .minutes
            value = m / unit.rawValue
        case .daily(let t): mode = .daily; times = dates(t)
        case .weekly(let d, let t): mode = .weekly; weekdays = d; times = dates(t)
        }
        _mode = State(initialValue: mode)
        _intervalValue = State(initialValue: value)
        _intervalUnit = State(initialValue: unit)
        _times = State(initialValue: times)
        _weekdays = State(initialValue: weekdays)

        var endMode = EndMode.never, until = Calendar.current.date(byAdding: .day, value: 7, to: .now)!, count = 10
        switch schedule.end {
        case .never: break
        case .until(let d): endMode = .until; until = d
        case .afterCount(let n): endMode = .count; count = n
        }
        _endMode = State(initialValue: endMode)
        _untilDate = State(initialValue: until)
        _count = State(initialValue: count)
    }

    var body: some View {
        NavigationStack {
            Form {
                noteSection
                spokenTitleSection
                repeatSection
                endSection
                optionsSection
            }
            .navigationTitle(note == nil ? "New note" : "Edit note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dictation.stop(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(!canSave || isSaving)
                }
            }
            .onChange(of: dictation.transcript) { _, text in details = text }
            .onChange(of: dictation.isRecording) { _, recording in
                if !recording && spokenTitle.isEmpty { Task { await suggestTitle() } }
            }
            .task {
                if startDictation { await dictation.start(language: LanguageDetector.fallback) }
            }
            .onDisappear { dictation.stop() }
        }
    }

    // MARK: Sections

    private var noteSection: some View {
        Section {
            TextField("What must you not forget?", text: $details, axis: .vertical)
                .lineLimit(3...10)
                .focused($textFocused)
            HStack {
                Button {
                    dictation.transcript = details
                    Task { await dictation.toggle(language: LanguageDetector.fallback) }
                } label: {
                    Label(dictation.isRecording ? "Stop" : "Dictate",
                          systemImage: dictation.isRecording ? "stop.circle.fill" : "mic.circle")
                        .symbolEffect(.pulse, isActive: dictation.isRecording)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.amber)
                Spacer()
                if dictation.isRecording {
                    Image(systemName: "waveform")
                        .symbolEffect(.variableColor.iterative, options: .repeating)
                        .foregroundStyle(Theme.amber)
                }
            }
            if let error = dictation.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        }
    }

    private var spokenTitleSection: some View {
        Section {
            TextField("Read aloud as…", text: $spokenTitle, axis: .vertical)
                .font(Theme.title(.body))
            HStack {
                Button {
                    Task { await suggestTitle(force: true) }
                } label: {
                    Label("Suggest", systemImage: "sparkles")
                }
                .disabled(details.isBlank || isGeneratingTitle)
                Spacer()
                if isGeneratingTitle { ProgressView() }
                Button {
                    let text = spokenTitle.isBlank ? SpokenTitle.fallback(from: details) : spokenTitle
                    SpeechRenderer.shared.speakNow(text, language: LanguageDetector.speechLanguage(for: text))
                } label: {
                    Label("Listen", systemImage: "speaker.wave.2")
                }
                .disabled(details.isBlank && spokenTitle.isBlank)
            }
            .buttonStyle(.borderless)
        } header: {
            Text("Spoken title")
        } footer: {
            Text("This short sentence is what Loopnote says out loud. The full note stays in the app.")
        }
    }

    private var repeatSection: some View {
        Section("Repeat") {
            Picker("Repeat", selection: $mode) {
                ForEach(RepeatMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            switch mode {
            case .once:
                DatePicker("At", selection: $start, in: Date.now...)
            case .interval:
                Stepper(value: $intervalValue, in: 1...999) {
                    HStack {
                        Text("Every")
                        Text("\(intervalValue)").monospacedDigit().fontWeight(.semibold)
                    }
                }
                Picker("Unit", selection: $intervalUnit) {
                    ForEach(IntervalUnit.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                DatePicker("Starting", selection: $start)
            case .daily:
                timesEditor
            case .weekly:
                WeekdayPicker(selection: $weekdays)
                timesEditor
            }
        }
    }

    private var timesEditor: some View {
        Group {
            ForEach(times.indices, id: \.self) { i in
                HStack {
                    DatePicker("Time", selection: $times[i], displayedComponents: .hourAndMinute)
                    if times.count > 1 {
                        Button(role: .destructive) { times.remove(at: i) } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            Button {
                times.append(times.last?.addingTimeInterval(3_600) ?? .now)
            } label: {
                Label("Add time", systemImage: "plus")
            }
        }
    }

    private var endSection: some View {
        Section("Ends") {
            Picker("Ends", selection: $endMode) {
                ForEach(EndMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            switch endMode {
            case .never: EmptyView()
            case .until: DatePicker("Last day", selection: $untilDate, in: Date.now...)
            case .count:
                Stepper(value: $count, in: 1...999) {
                    Text("\(count) times").monospacedDigit()
                }
            }
        }
        .disabled(mode == .once)
    }

    private var optionsSection: some View {
        Section {
            Picker("Project", selection: $projectID) {
                Text("None").tag(UUID?.none)
                ForEach(projects) { p in
                    Text(p.name).tag(UUID?.some(p.id))
                }
            }
            Toggle(isOn: $isCritical) {
                Label("Critical", systemImage: "bell.badge")
            }
        } footer: {
            Text("Critical notes break through Focus as time-sensitive alerts.")
        }
    }

    // MARK: Logic

    private var canSave: Bool {
        !details.isBlank && rule.isValid && !(mode == .weekly && weekdays.isEmpty)
    }

    private var rule: RepeatRule {
        let tods = times.map { d -> TimeOfDay in
            let c = Calendar.current.dateComponents([.hour, .minute], from: d)
            return TimeOfDay(hour: c.hour ?? 9, minute: c.minute ?? 0)
        }
        switch mode {
        case .once: return .once
        case .interval: return .interval(minutes: intervalValue * intervalUnit.rawValue)
        case .daily: return .daily(times: tods)
        case .weekly: return .weekly(weekdays: weekdays, times: tods)
        }
    }

    private var endCondition: EndCondition {
        guard mode != .once else { return .never }
        switch endMode {
        case .never: return .never
        case .until:
            let endOfDay = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: untilDate) ?? untilDate
            return .until(endOfDay)
        case .count: return .afterCount(count)
        }
    }

    private func suggestTitle(force: Bool = false) async {
        guard !details.isBlank, force || spokenTitle.isBlank else { return }
        isGeneratingTitle = true
        let language = LanguageDetector.speechLanguage(for: details)
        spokenTitle = await TitleSummarizer.spokenTitle(for: details, language: language)
        isGeneratingTitle = false
    }

    private func save() async {
        isSaving = true
        dictation.stop()
        let text = details.trimmingCharacters(in: .whitespacesAndNewlines)
        if spokenTitle.isBlank { await suggestTitle(force: true) }
        let title = spokenTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let language = LanguageDetector.speechLanguage(for: title.isEmpty ? text : title)
        let startDate: Date = {
            switch mode {
            case .once, .interval: return start
            case .daily, .weekly: return note?.schedule.start ?? Calendar.current.startOfDay(for: .now)
            }
        }()
        let schedule = NoteSchedule(start: startDate, rule: rule, end: endCondition)
        let project = projects.first { $0.id == projectID }

        if let note {
            note.details = text
            note.spokenTitle = title
            note.languageCode = language
            note.isCritical = isCritical
            note.project = project
            note.schedule = schedule
            note.snoozedUntil = nil
        } else {
            context.insert(Note(details: text, spokenTitle: title, schedule: schedule,
                                languageCode: language, isCritical: isCritical, project: project))
        }
        try? context.save()
        await AlertScheduler.shared.reschedule()
        isSaving = false
        dismiss()
    }
}

/// Seven round toggles, ordered by the user's first weekday.
struct WeekdayPicker: View {
    @Binding var selection: Set<Int>

    var body: some View {
        let cal = Calendar.current
        let symbols = cal.veryShortWeekdaySymbols
        let order = (0..<7).map { (cal.firstWeekday - 1 + $0) % 7 + 1 }
        HStack {
            ForEach(order, id: \.self) { day in
                let on = selection.contains(day)
                Button {
                    if on { selection.remove(day) } else { selection.insert(day) }
                } label: {
                    Text(symbols[day - 1])
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(on ? Theme.amber : Color.secondary.opacity(0.12)))
                        .foregroundStyle(on ? Color.black : Color.primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(cal.weekdaySymbols[day - 1])
                .accessibilityAddTraits(on ? .isSelected : [])
                if day != order.last { Spacer(minLength: 0) }
            }
        }
        .padding(.vertical, 4)
    }
}

extension String {
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
