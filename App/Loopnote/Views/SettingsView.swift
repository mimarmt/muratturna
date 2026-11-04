import AVFoundation
import UIKit
import SwiftUI
import UserNotifications

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @AppStorage(AppSettings.Key.quietEnabled) private var quietEnabled = true
    @AppStorage(AppSettings.Key.quietStart) private var quietStart = 23 * 60
    @AppStorage(AppSettings.Key.quietEnd) private var quietEnd = 7 * 60 + 30
    @AppStorage(AppSettings.Key.usePersonalVoice) private var usePersonalVoice = false
    @AppStorage(AppSettings.Key.speechRate) private var speechRate = 0.5
    @AppStorage(AppSettings.Key.nextNoteActivity) private var nextNoteActivity = true

    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined

    var body: some View {
        Form {
            Section {
                if ProStore.shared.isPro {
                    Label(ProStore.shared.isTestBuild ? "Loopnote Pro (TestFlight)" : "Loopnote Pro", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(Theme.amber)
                } else {
                    Button { ProStore.shared.showPaywall = true } label: {
                        Label("Get Loopnote Pro", systemImage: "seal")
                    }
                }
                Button("Restore purchases") { Task { await ProStore.shared.restore() } }
            }

            Section {
                Toggle("Quiet hours", isOn: $quietEnabled)
                if quietEnabled {
                    DatePicker("From", selection: minutes($quietStart), displayedComponents: .hourAndMinute)
                    DatePicker("Until", selection: minutes($quietEnd), displayedComponents: .hourAndMinute)
                }
            } footer: {
                Text("Notes due during quiet hours are read together when quiet hours end.")
            }

            ElevenLabsSection()

            Section {
                ForEach(VoiceCatalog.languages, id: \.self) { lang in
                    VoicePickerRow(language: lang)
                }
                let compact = VoiceCatalog.languages.filter(VoiceCatalog.onlyCompactInstalled)
                if !compact.isEmpty {
                    Label {
                        Text("Only compact voices for \(compact.map(VoicePickerRow.shortName).formatted(.list(type: .and))). Download an Enhanced voice in Settings › Accessibility › Read & Speak › Voices.")
                            .font(.footnote)
                    } icon: {
                        Image(systemName: "sparkles").foregroundStyle(Theme.amber)
                    }
                }
            } header: {
                Text("Apple voices")
            } footer: {
                Text("Each note is read in its own language. Apple voices are also used when ElevenLabs is off or offline.")
            }

            Section {
                Toggle(isOn: $usePersonalVoice) {
                    Label("Use my Personal Voice", systemImage: "person.wave.2")
                }
                .onChange(of: usePersonalVoice) { _, on in
                    guard on else { return }
                    if !ProStore.shared.require() { usePersonalVoice = false; return }
                    Task {
                        if !(await VoiceCatalog.requestPersonalVoice()) { usePersonalVoice = false }
                    }
                }
                VStack(alignment: .leading) {
                    Text("Speaking rate")
                    Slider(value: $speechRate, in: 0.35...0.6) {
                        Text("Speaking rate")
                    } minimumValueLabel: {
                        Image(systemName: "tortoise")
                    } maximumValueLabel: {
                        Image(systemName: "hare")
                    }
                }
                Button {
                    SpeechRenderer.shared.speakNow(String(localized: "This is how your notes will sound."),
                                                   language: LanguageDetector.fallback)
                } label: {
                    Label("Preview voice", systemImage: "speaker.wave.2")
                }
            } header: {
                Text("Voice")
            } footer: {
                Text("Personal Voice speaks English notes in your own voice. Create it in Settings › Accessibility › Personal Voice and allow apps to request it.")
            }

            Section {
                Toggle(isOn: $nextNoteActivity) {
                    Label("Next note on Lock Screen", systemImage: "platter.filled.bottom.iphone")
                }
                .onChange(of: nextNoteActivity) { _, _ in Task { await AlertScheduler.shared.reschedule() } }
            } footer: {
                Text("Shows a countdown to the next note on the Lock Screen and in the Dynamic Island when it speaks within 8 hours.")
            }

            Section("Notifications") {
                LabeledContent("Status", value: statusText)
                if notificationStatus == .denied {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                } else if notificationStatus == .notDetermined {
                    Button("Allow notifications") {
                        Task {
                            _ = await AlertScheduler.shared.requestAuthorization()
                            await refreshStatus()
                        }
                    }
                }
            }

            Section {
                LabeledContent("Version", value: Bundle.main.versionString)
                LabeledContent("On-device intelligence",
                               value: TitleSummarizer.isModelAvailable ? String(localized: "Available")
                                                                        : String(localized: "Not available"))
            } footer: {
                Text("Your notes stay on your device. Speech and titles are processed on device.")
            }
        }
        .navigationTitle("Settings")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .task { await refreshStatus() }
        .onDisappear { Task { await AlertScheduler.shared.reschedule() } }
    }

    private var statusText: String {
        switch notificationStatus {
        case .authorized, .provisional, .ephemeral: String(localized: "On")
        case .denied: String(localized: "Off")
        default: String(localized: "Not set")
        }
    }

    private func refreshStatus() async {
        notificationStatus = await AlertScheduler.shared.authorizationStatus()
    }

    /// Bridges minutes-since-midnight storage to a time picker.
    private func minutes(_ value: Binding<Int>) -> Binding<Date> {
        Binding {
            Calendar.current.date(bySettingHour: value.wrappedValue / 60, minute: value.wrappedValue % 60,
                                  second: 0, of: .now) ?? .now
        } set: { date in
            let c = Calendar.current.dateComponents([.hour, .minute], from: date)
            value.wrappedValue = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        }
    }
}

extension Bundle {
    var versionString: String {
        let v = infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }
}

/// Picks the voice used for one language, with a quality label and preview.
private struct VoicePickerRow: View {
    let language: String
    @State private var selection: String = ""

    private var voices: [AVSpeechSynthesisVoice] { VoiceCatalog.voices(for: language) }
    static func shortName(_ language: String) -> String {
        Locale.current.localizedString(forLanguageCode: String(language.prefix(2)))?.localizedCapitalized ?? language
    }

    var body: some View {
        HStack {
            Picker(Self.shortName(language), selection: $selection) {
                Text("Automatic").tag("")
                ForEach(voices, id: \.identifier) { v in
                    Text("\(v.name.replacingOccurrences(of: " (Enhanced)", with: "").replacingOccurrences(of: " (Premium)", with: "")) · \(VoiceCatalog.qualityLabel(v))")
                        .tag(v.identifier)
                }
            }
            .pickerStyle(.menu)
        }
        .onAppear { selection = AppSettings.voiceIdentifier(for: language) ?? "" }
        .onChange(of: selection) { old, id in
            UserDefaults.standard.set(id, forKey: AppSettings.voiceKey(for: language))
            if old != id { preview() }
        }
    }

    /// Plays a sample with the Apple voice just chosen.
    private func preview() {
        let sample = switch language.prefix(2) {
        case "tr": "Yarın saat onda belediyeye eksik evrakları götür."
        case "de": "Morgen um zehn die fehlenden Unterlagen zum Bauamt bringen."
        default: "Bring the missing documents to the city office tomorrow at ten."
        }
        let synth = AVSpeechSynthesizer.previewSynth
        let u = AVSpeechUtterance(string: sample)
        u.voice = VoiceCatalog.voice(for: language, allowPersonal: false)
        u.rate = AppSettings.speechRate
        synth.stopSpeaking(at: .immediate)
        synth.speak(u)
    }
}

/// Bring-your-own-key ElevenLabs voices (testing phase; a server proxy replaces this before release).
private struct ElevenLabsSection: View {
    @AppStorage(AppSettings.Key.elevenEnabled) private var enabled = false
    @AppStorage(AppSettings.Key.elevenVoiceID) private var voiceID = ""
    @AppStorage(AppSettings.Key.elevenVoiceName) private var voiceName = ""
    @AppStorage(AppSettings.Key.elevenModel) private var model = ElevenLabsClient.Model.multilingualV2.rawValue

    @State private var keyDraft = ""
    @State private var hasKey = ElevenLabsClient.apiKey != nil
    @State private var voices: [ElevenLabsClient.Voice] = []
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        Section {
            Toggle(isOn: $enabled) {
                Label("Natural voice (ElevenLabs)", systemImage: "waveform.badge.plus")
            }
            if enabled {
                if hasKey {
                    LabeledContent("API key") {
                        Button("Remove", role: .destructive) {
                            Keychain.set(nil, for: ElevenLabsClient.keyAccount)
                            hasKey = false
                            voices = []
                        }
                    }
                    Picker("Voice", selection: $voiceID) {
                        if voiceID.isEmpty { Text("Choose…").tag("") }
                        if !voiceID.isEmpty && !voices.contains(where: { $0.voice_id == voiceID }) {
                            Text(voiceName.isEmpty ? voiceID : voiceName).tag(voiceID)
                        }
                        ForEach(voices) { v in
                            let short = ElevenLabsClient.shortName(v.name)
                            Text(v.category == "cloned" ? "\(short) ★" : short).tag(v.voice_id)
                        }
                    }
                    NavigationLink {
                        SharedVoicesView(language: "tr") { newID, name in
                            Task {
                                await loadVoices()
                                voiceID = newID
                                voiceName = name
                            }
                        }
                    } label: {
                        Label("Find a Turkish voice", systemImage: "magnifyingglass")
                    }
                    Picker("Model", selection: $model) {
                        ForEach(ElevenLabsClient.Model.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    Button {
                        Task { await preview() }
                    } label: {
                        Label("Preview natural voice", systemImage: "play.circle")
                    }
                    .disabled(voiceID.isEmpty || loading)
                } else {
                    Link(destination: URL(string: "https://elevenlabs.io/app/developers/api-keys")!) {
                        Label("1. Create a key on elevenlabs.io", systemImage: "arrow.up.right.square")
                    }
                    PasteButton(payloadType: String.self) { strings in
                        let key = (strings.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        Task { @MainActor in
                            Keychain.set(key, for: ElevenLabsClient.keyAccount)
                            hasKey = ElevenLabsClient.apiKey != nil
                            await loadVoices()
                        }
                    }
                    .labelStyle(.titleAndIcon)
                    .tint(Theme.amber)
                    Text("2. Copy the key there, then tap Paste.")
                        .font(.footnote).foregroundStyle(.secondary)
                    SecureField("ElevenLabs API key", text: $keyDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Save key") {
                        Keychain.set(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines),
                                     for: ElevenLabsClient.keyAccount)
                        keyDraft = ""
                        hasKey = ElevenLabsClient.apiKey != nil
                        Task { await loadVoices() }
                    }
                    .disabled(keyDraft.isBlank)
                }
                if loading { ProgressView() }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            }
        } header: {
            Text("Natural voice")
        } footer: {
            Text("Only the short spoken title is sent to ElevenLabs, once per note; the audio is stored on your iPhone. ★ marks your cloned voices. Create a key at elevenlabs.io › Developers › API keys.")
        }
        .task(id: hasKey) { if enabled && hasKey && voices.isEmpty { await loadVoices() } }
        .onChange(of: enabled) { _, on in
            if on && !ProStore.shared.require() { enabled = false; return }
            if on && hasKey && voices.isEmpty { Task { await loadVoices() } }
        }
        .onChange(of: voiceID) { _, id in
            voiceName = voices.first { $0.voice_id == id }?.name ?? voiceName
        }
    }

    private func loadVoices() async {
        loading = true
        defer { loading = false }
        do {
            voices = try await ElevenLabsClient.voices()
            error = nil
            if voiceID.isEmpty, let first = voices.first { voiceID = first.voice_id }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func preview() async {
        loading = true
        defer { loading = false }
        do {
            try await SpeechRenderer.shared.previewElevenLabs(
                "Yarın saat onda belediyeye eksik evrakları götürmeyi unutma.",
                voiceID: voiceID, model: model)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Browses native-speaker voices in the ElevenLabs Voice Library and adds one to the account.
private struct SharedVoicesView: View {
    let language: String
    var onAdded: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var voices: [ElevenLabsClient.SharedVoice] = []
    @State private var loading = true
    @State private var adding: String?
    @State private var error: String?
    @State private var player: AVPlayer?
    @State private var playing: String?

    var body: some View {
        List {
            if let error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            ForEach(voices) { v in
                HStack(spacing: 14) {
                    Button {
                        play(v)
                    } label: {
                        Image(systemName: playing == v.voice_id ? "stop.circle.fill" : "play.circle.fill")
                            .font(.title)
                            .foregroundStyle(Theme.amber)
                    }
                    .buttonStyle(.borderless)
                    .disabled(v.preview_url == nil)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(ElevenLabsClient.shortName(v.name)).font(Theme.title(.body))
                        Text(details(v)).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    if adding == v.voice_id {
                        ProgressView()
                    } else {
                        Button("Add") { Task { await add(v) } }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.amber)
                            .foregroundStyle(.black)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .overlay { if loading { ProgressView() } }
        .navigationTitle("Turkish voices")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onDisappear { player?.pause() }
    }

    private func details(_ v: ElevenLabsClient.SharedVoice) -> String {
        [v.gender, v.age, v.descriptive, v.use_case]
            .compactMap { $0?.replacingOccurrences(of: "_", with: " ") }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            voices = try await ElevenLabsClient.sharedVoices(language: language)
            error = voices.isEmpty ? String(localized: "No voices found.") : nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func play(_ v: ElevenLabsClient.SharedVoice) {
        if playing == v.voice_id {
            player?.pause(); playing = nil; return
        }
        guard let s = v.preview_url, let url = URL(string: s) else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        player = AVPlayer(url: url)
        player?.play()
        playing = v.voice_id
    }

    private func add(_ v: ElevenLabsClient.SharedVoice) async {
        adding = v.voice_id
        defer { adding = nil }
        do {
            let id = try await ElevenLabsClient.addSharedVoice(v)
            player?.pause()
            onAdded(id, ElevenLabsClient.shortName(v.name))
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

extension AVSpeechSynthesizer {
    /// Shared synthesizer for voice previews in Settings.
    @MainActor static let previewSynth = AVSpeechSynthesizer()
}
