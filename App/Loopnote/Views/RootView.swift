import SwiftUI

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppSettings.Key.onboarded) private var onboarded = false

    @Bindable private var router = AppRouter.shared
    @Bindable private var pro = ProStore.shared

    var body: some View {
        TabView(selection: $router.tab) {
            Tab("Notes", systemImage: "waveform", value: AppRouter.Tab.notes) {
                NavigationStack { NotesListView() }
            }
            Tab("Meetings", systemImage: "person.2.wave.2", value: AppRouter.Tab.meetings) {
                NavigationStack { MeetingsListView() }
            }
        }
        .tint(Theme.amber)
        .fullScreenCover(isPresented: $router.showMeetingRecorder) {
            MeetingRecorderView()
        }
        .sheet(isPresented: $pro.showPaywall) { PaywallView() }
        .sheet(isPresented: Binding(get: { !onboarded }, set: { _ in })) {
            OnboardingView { onboarded = true }
                .interactiveDismissDisabled()
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active {
                Task { await AlertScheduler.shared.reschedule() }
            }
        }
    }
}

struct OnboardingView: View {
    var onFinish: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Image(systemName: "waveform.circle")
                .font(.system(size: 88, weight: .ultraLight))
                .foregroundStyle(Theme.amber)
                .symbolEffect(.variableColor.iterative, options: .repeating)
            VStack(spacing: 12) {
                Text("Notes that speak up")
                    .font(Theme.title(.largeTitle))
                    .multilineTextAlignment(.center)
                Text("Loopnote reads your notes aloud on the schedule you choose, until you mark them done.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)
            VStack(alignment: .leading, spacing: 18) {
                Feature(symbol: "mic", text: "Speak or type a note")
                Feature(symbol: "repeat", text: "Repeat it every few minutes, hours or days")
                Feature(symbol: "speaker.wave.2", text: "Hear it on the Lock Screen and in your AirPods")
                Feature(symbol: "moon", text: "Quiet at night, summarized in the morning")
            }
            .padding(.horizontal, 40)
            Spacer()
            Button {
                Task {
                    _ = await AlertScheduler.shared.requestAuthorization()
                    onFinish()
                }
            } label: {
                Text("Allow notifications and start")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        }
    }

    private struct Feature: View {
        let symbol: String
        let text: LocalizedStringKey
        var body: some View {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .frame(width: 28)
                    .foregroundStyle(Theme.amber)
                Text(text)
            }
        }
    }
}
