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

    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined

    var body: some View {
        Form {
            Section {
                Toggle("Quiet hours", isOn: $quietEnabled)
                if quietEnabled {
                    DatePicker("From", selection: minutes($quietStart), displayedComponents: .hourAndMinute)
                    DatePicker("Until", selection: minutes($quietEnd), displayedComponents: .hourAndMinute)
                }
            } footer: {
                Text("Notes due during quiet hours are read together when quiet hours end.")
            }

            Section {
                ForEach(VoiceCatalog.languages, id: \.self) { lang in
                    VoicePickerRow(language: lang)
                }
                if VoiceCatalog.languages.contains(where: VoiceCatalog.onlyCompactInstalled) {
                    Label {
                        Text("For a more natural sound, download an Enhanced or Premium voice: Settings › Accessibility › Read & Speak › Voices.")
                            .font(.footnote)
                    } icon: {
                        Image(systemName: "sparkles").foregroundStyle(Theme.amber)
                    }
                }
            } header: {
                Text("Voices")
            } footer: {
                Text("Each note is read in its own language with the voice you choose here.")
            }

            Section {
                Toggle(isOn: $usePersonalVoice) {
                    Label("Use my Personal Voice", systemImage: "person.wave.2")
                }
                .onChange(of: usePersonalVoice) { _, on in
                    guard on else { return }
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
    private var languageName: String {
        Locale.current.localizedString(forIdentifier: language) ?? language
    }

    var body: some View {
        HStack {
            Picker(languageName, selection: $selection) {
                Text("Automatic").tag("")
                ForEach(voices, id: \.identifier) { v in
                    Text("\(v.name) · \(VoiceCatalog.qualityLabel(v))").tag(v.identifier)
                }
            }
            Button {
                let sample = switch language.prefix(2) {
                case "tr": "Yarın saat onda belediyeye eksik evrakları götür."
                case "de": "Morgen um zehn die fehlenden Unterlagen zum Bauamt bringen."
                default: "Bring the missing documents to the city office tomorrow at ten."
                }
                SpeechRenderer.shared.speakNow(sample, language: language)
            } label: {
                Image(systemName: "play.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Preview voice")
        }
        .onAppear { selection = AppSettings.voiceIdentifier(for: language) ?? "" }
        .onChange(of: selection) { _, id in
            UserDefaults.standard.set(id, forKey: AppSettings.voiceKey(for: language))
        }
    }
}
