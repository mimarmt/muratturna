import Foundation
import SwiftData
import WatchConnectivity
import WidgetKit
import LoopnoteCore

/// Sends the active notes to Apple Watch and applies actions coming back from it.
@MainActor
final class WatchSync: NSObject, WCSessionDelegate {
    static let shared = WatchSync()

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Latest-state snapshot (replaces the previous one on the watch).
    func send(_ notes: [Note]) {
        let snapshot = notes
            .filter { $0.isActive }
            .sorted { ($0.nextOccurrence() ?? .distantFuture) < ($1.nextOccurrence() ?? .distantFuture) }
            .prefix(40)
            .map { n in
                WatchNote(id: n.id, title: n.textToSpeak,
                          subtitle: n.hasLocation ? (n.locationName ?? "") : (n.project?.name ?? ""),
                          next: n.nextOccurrence(), isCritical: n.isCritical,
                          awaitingDone: n.isAwaitingConfirmation)
            }
        // Home Screen and Lock Screen widgets read the same snapshot from the App Group.
        SharedNotes.save(Array(snapshot.prefix(10)))
        WidgetCenter.shared.reloadTimelines(ofKind: SharedNotes.widgetKind)

        let session = WCSession.default
        guard WCSession.isSupported(), session.activationState == .activated,
              session.isPaired, session.isWatchAppInstalled else { return }
        try? session.updateApplicationContext(WatchMessage.snapshot(Array(snapshot)).payload)
    }

    private func apply(_ data: Data) async {
        guard let message = try? JSONDecoder().decode(WatchMessage.self, from: data) else { return }
        switch message {
        case .complete(let id):
            await AlertScheduler.shared.handle(action: AlertScheduler.Action.complete, noteID: id)
        case .newNote(let text):
            let context = Persistence.container.mainContext
            let language = LanguageDetector.speechLanguage(for: text)
            let title = await TitleSummarizer.spokenTitle(for: text, language: language)
            let schedule: NoteSchedule
            if let date = MeetingDetailView.detectDate(in: text), date > .now {
                schedule = NoteSchedule(start: date, rule: .once)
            } else {
                schedule = NoteSchedule(start: .now, rule: .daily(times: [TimeOfDay(hour: 9, minute: 0)]))
            }
            context.insert(Note(details: text, spokenTitle: title, schedule: schedule, languageCode: language))
            try? context.save()
            await AlertScheduler.shared.reschedule()
        case .snapshot:
            break
        }
    }

    // MARK: WCSessionDelegate

    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState,
                             error: Error?) {
        Task { @MainActor in await AlertScheduler.shared.reschedule() }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard let data = userInfo[WatchMessage.key] as? Data else { return }
        Task { @MainActor in await self.apply(data) }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
}
