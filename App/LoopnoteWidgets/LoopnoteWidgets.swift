import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct LoopnoteWidgetsBundle: WidgetBundle {
    var body: some Widget {
        NotesWidget()
        StartMeetingControl()
        VoiceNoteControl()
        LoopnoteLiveActivity()
    }
}

// MARK: Controls (Control Center, Lock Screen, Action button)

struct StartMeetingControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.muratturna.loopnote.control.meeting") {
            ControlWidgetButton(action: StartMeetingIntent()) {
                Label("Record meeting", systemImage: "person.2.wave.2")
            }
        }
        .displayName("Record meeting")
        .description("Start recording a meeting in Loopnote.")
    }
}

struct VoiceNoteControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.muratturna.loopnote.control.voicenote") {
            ControlWidgetButton(action: NewVoiceNoteIntent()) {
                Label("Voice note", systemImage: "waveform.badge.mic")
            }
        }
        .displayName("Voice note")
        .description("Dictate a living note in Loopnote.")
    }
}

// MARK: Live Activity

struct LoopnoteLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LoopnoteActivityAttributes.self) { context in
            LockScreenActivityView(kind: context.attributes.kind, state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.75))
                .activitySystemActionForegroundColor(Brand.amber)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: icon(context.attributes.kind))
                        .font(.title2)
                        .foregroundStyle(Brand.amber)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    TimeText(kind: context.attributes.kind, state: context.state)
                        .font(.title3.monospacedDigit())
                        .foregroundStyle(Brand.amber)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.title)
                        .font(.system(.headline, design: .serif))
                        .lineLimit(2)
                }
            } compactLeading: {
                Image(systemName: icon(context.attributes.kind)).foregroundStyle(Brand.amber)
            } compactTrailing: {
                TimeText(kind: context.attributes.kind, state: context.state)
                    .monospacedDigit()
                    .frame(maxWidth: 56)
                    .foregroundStyle(Brand.amber)
            } minimal: {
                Image(systemName: icon(context.attributes.kind)).foregroundStyle(Brand.amber)
            }
            .keylineTint(Brand.amber)
        }
    }

    private func icon(_ kind: LoopnoteActivityAttributes.Kind) -> String {
        kind == .meeting ? "record.circle" : "waveform"
    }
}

private struct TimeText: View {
    let kind: LoopnoteActivityAttributes.Kind
    let state: LoopnoteActivityAttributes.ContentState

    var body: some View {
        switch kind {
        case .meeting:
            if state.paused {
                Image(systemName: "pause.fill")
            } else {
                Text(state.date, style: .timer)
            }
        case .nextNote:
            Text(timerInterval: Date.now...max(state.date, Date.now), countsDown: true)
        }
    }
}

private struct LockScreenActivityView: View {
    let kind: LoopnoteActivityAttributes.Kind
    let state: LoopnoteActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: kind == .meeting ? "record.circle" : "waveform.circle")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Brand.amber)
            VStack(alignment: .leading, spacing: 4) {
                Text(kind == .meeting ? "Recording meeting" : "Next note")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(state.title)
                    .font(.system(.headline, design: .serif))
                    .lineLimit(2)
            }
            Spacer()
            TimeText(kind: kind, state: state)
                .font(.title3.monospacedDigit())
                .foregroundStyle(Brand.amber)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 90)
        }
        .padding(16)
    }
}
