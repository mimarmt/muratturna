import SwiftData
import SwiftUI

/// Full-screen meeting recorder: consent, live waveform, pause, finish.
struct MeetingRecorderView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Project.createdAt) private var projects: [Project]

    @State private var recorder = MeetingRecorder()
    @State private var consent = false
    @State private var language = LanguageDetector.fallback
    @State private var projectID: UUID?
    @State private var confirmDiscard = false
    @State private var finishing = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                if recorder.state == .idle {
                    setup
                } else {
                    recording
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(recorder.state == .idle ? "Cancel" : "Discard", role: .cancel) {
                        if recorder.state == .idle { dismiss() } else { confirmDiscard = true }
                    }
                }
            }
            .confirmationDialog("Discard this recording?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard", role: .destructive) { recorder.discard(); dismiss() }
            }
            .interactiveDismissDisabled(recorder.state != .idle)
        }
    }

    // MARK: Before recording

    private var setup: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "person.2.wave.2")
                .font(.system(size: 64, weight: .ultraLight))
                .foregroundStyle(Theme.amber)
            Text("Record a meeting")
                .font(Theme.title(.largeTitle))
            Text("Loopnote writes the minutes, finds decisions and action items, and turns each action into a reminder that speaks until it is done.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                Picker("Language", selection: $language) {
                    ForEach(VoiceCatalog.languages, id: \.self) { lang in
                        Text(VoicePickerRowName.short(lang)).tag(lang)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.bottom, 14)
                if !projects.isEmpty {
                    Picker("Project", selection: $projectID) {
                        Text("No project").tag(UUID?.none)
                        ForEach(projects) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                    .padding(.bottom, 8)
                }
                Toggle(isOn: $consent) {
                    Text("I have told everyone that this meeting is being recorded")
                        .font(.subheadline)
                }
                .tint(Theme.amber)
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 20).fill(Color.secondary.opacity(0.08)))

            if let e = recorder.errorMessage {
                Text(e).font(.footnote).foregroundStyle(.red)
            }
            Spacer()
            Button {
                Task { _ = await recorder.start() }
            } label: {
                Label("Start recording", systemImage: "record.circle")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.extraLarge)
            .disabled(!consent)
        }
    }

    // MARK: While recording

    private var recording: some View {
        VStack(spacing: 32) {
            Spacer()
            HStack(spacing: 8) {
                Circle().fill(recorder.state == .recording ? Color.red : Color.secondary)
                    .frame(width: 10, height: 10)
                    .opacity(recorder.state == .recording ? 1 : 0.5)
                Text(recorder.state == .recording ? "Recording" : "Paused")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(Duration.seconds(recorder.elapsed).formatted(.time(pattern: .hourMinuteSecond)))
                .font(.system(size: 64, weight: .light, design: .serif))
                .monospacedDigit()
                .contentTransition(.numericText())
            WaveformView(levels: recorder.levels)
                .frame(height: 90)
            Text("You can lock your iPhone. Recording continues.")
                .font(.footnote).foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 20) {
                Button {
                    recorder.state == .recording ? recorder.pause() : recorder.resume()
                } label: {
                    Image(systemName: recorder.state == .recording ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 64, height: 64)
                }
                .buttonStyle(.glass)
                .accessibilityLabel(recorder.state == .recording ? "Pause" : "Resume")

                Button { finish() } label: {
                    Label("Finish", systemImage: "stop.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 64)
                }
                .buttonStyle(.glassProminent)
                .disabled(finishing)
            }
        }
    }

    private func finish() {
        guard !finishing else { return }
        finishing = true
        Trace.log("recorder: finish tapped")
        guard let result = recorder.stop() else { dismiss(); return }
        Trace.log("recorder: stopped, \(Int(result.duration)) s")
        let title = String(localized: "Meeting") + " " + Date.now.formatted(date: .abbreviated, time: .shortened)
        let meeting = Meeting(title: title, audioFileName: result.fileName,
                              duration: result.duration, language: language)
        meeting.project = projects.first { $0.id == projectID }
        context.insert(meeting)
        try? context.save()
        AppRouter.shared.openMeeting(meeting.id)
        // Close the recorder at once. Processing starts once the audio file is closed,
        // which happens off the main thread and never holds up the screen.
        Trace.log("recorder: meeting saved, closing")
        AppRouter.shared.showMeetingRecorder = false
        dismiss()
        let recorder = recorder
        Task {
            await recorder.waitUntilFinalized()
            Trace.log("recorder: file closed, processing")
            MeetingProcessor.shared.start(meeting)
        }
    }
}

/// Live input level bars.
struct WaveformView: View {
    let levels: [Float]

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .center, spacing: 3) {
                ForEach(levels.indices, id: \.self) { i in
                    Capsule()
                        .fill(Theme.amber.gradient)
                        .frame(height: max(4, CGFloat(levels[i]) * geo.size.height))
                }
            }
            .frame(maxHeight: .infinity)
            .animation(.easeOut(duration: 0.1), value: levels)
        }
        .accessibilityHidden(true)
    }
}

enum VoicePickerRowName {
    static func short(_ language: String) -> String {
        Locale.current.localizedString(forLanguageCode: String(language.prefix(2)))?.localizedCapitalized ?? language
    }
}
