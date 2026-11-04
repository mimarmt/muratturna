import AVFoundation
import BackgroundTasks
import Foundation
import FoundationModels
import Speech
import SwiftData
import UIKit

/// Turns a recorded meeting into a transcript and AI minutes.
@MainActor
final class MeetingProcessor {
    static let shared = MeetingProcessor()
    static let taskPrefix = "com.muratturna.loopnote.meeting."

    /// Meetings being processed right now (so resume never runs one twice).
    private var inFlight = Set<UUID>()

    /// Starts processing as a continued background task (iOS 26): it keeps running when the
    /// app goes to the background, with progress shown by the system. Falls back to a
    /// foreground task if the system declines the request.
    func start(_ meeting: Meeting) {
        let id = meeting.id
        guard !inFlight.contains(id) else { return }
        let identifier = Self.taskPrefix + id.uuidString.replacingOccurrences(of: "-", with: "")
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let task = task as? BGContinuedProcessingTask else { return }
            nonisolated(unsafe) let bgTask = task
            Task { @MainActor in
                let ok = await MeetingProcessor.shared.run(id: id, task: bgTask)
                bgTask.setTaskCompleted(success: ok)
            }
        }
        if registered {
            let request = BGContinuedProcessingTaskRequest(
                identifier: identifier,
                title: String(localized: "Writing meeting minutes"),
                subtitle: String(localized: "Transcribing…"))
            request.strategy = .fail
            if (try? BGTaskScheduler.shared.submit(request)) != nil { return }
        }
        Task { _ = await run(id: id, task: nil) }
    }

    /// Restarts meetings left unfinished (app suspended or killed while processing).
    func resumePending() {
        let context = Persistence.container.mainContext
        let pending = (try? context.fetch(FetchDescriptor<Meeting>())) ?? []
        for m in pending where [.recorded, .transcribing, .summarizing].contains(m.status) && !inFlight.contains(m.id) {
            Task { _ = await run(id: m.id, task: nil) }
        }
    }

    func isProcessing(_ id: UUID) -> Bool { inFlight.contains(id) }

    private func run(id: UUID, task: BGContinuedProcessingTask?) async -> Bool {
        guard !inFlight.contains(id) else { return false }
        let context = Persistence.container.mainContext
        guard let meeting = try? context.fetch(FetchDescriptor<Meeting>(predicate: #Predicate { $0.id == id })).first
        else { return false }
        inFlight.insert(id)
        defer { inFlight.remove(id) }
        task?.progress.totalUnitCount = 100
        task?.progress.completedUnitCount = 5
        nonisolated(unsafe) let bg = task
        task?.expirationHandler = {
            Task { @MainActor in bg?.progress.cancel() }
        }
        return await process(meeting, task: task)
    }

    private func process(_ meeting: Meeting, task: BGContinuedProcessingTask?) async -> Bool {
        guard let url = meeting.audioURL else { return false }
        let context = Persistence.container.mainContext

        if meeting.transcript.isEmpty {
            meeting.status = .transcribing
            try? context.save()
            do {
                let language = meeting.language ?? LanguageDetector.fallback
                meeting.transcript = try await MeetingTranscription.transcribe(url, language: language,
                                                                               duration: meeting.duration)
            } catch {
                meeting.status = .failed
                meeting.errorMessage = error.localizedDescription
                try? context.save()
                return false
            }
        }
        task?.progress.completedUnitCount = 70
        task?.updateTitle(String(localized: "Writing meeting minutes"),
                          subtitle: String(localized: "Finding decisions and action items…"))
        guard !meeting.transcript.isBlank else {
            meeting.status = .failed
            meeting.errorMessage = String(localized: "No speech was found in the recording.")
            try? context.save()
            return false
        }

        meeting.status = .summarizing
        try? context.save()
        let language = LanguageDetector.speechLanguage(for: meeting.transcript)
        meeting.language = language
        let minutes = await MeetingSummarizer.minutes(for: meeting.transcript, language: language)
        if meeting.title.isEmpty || meeting.title.hasPrefix(String(localized: "Meeting")) {
            if !minutes.title.isBlank { meeting.title = minutes.title }
        }
        meeting.summary = minutes.summary
        meeting.decisions = minutes.decisions
        meeting.actions = minutes.actions
        meeting.status = .ready
        meeting.errorMessage = nil
        try? context.save()
        task?.progress.completedUnitCount = 100
        return true
    }

    /// Public entry for "Try again".
    func retry(_ meeting: Meeting) {
        meeting.status = .recorded
        meeting.errorMessage = nil
        start(meeting)
    }
}

/// Long-form, on-device transcription of an audio file.
enum MeetingTranscription {
    enum Failure: LocalizedError {
        case unsupported
        var errorDescription: String? { String(localized: "Speech recognition isn’t available for this language on this device.") }
    }

    static func transcribe(_ url: URL, language: String, duration: Double) async throws -> String {
        if let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) {
            // Diarization is a bonus: never let it hold up the transcript.
            let limit = max(90, duration * 0.8)
            async let spans = SpeakerDiarization.speakers(in: url, timeout: limit)
            let pieces = try await withSpeechAnalyzer(url, locale: locale)
            return SpeakerDiarization.label(pieces, with: await spans)
        }
        return try await withLegacyRecognizer(url, language: language)
    }

    /// iOS 26 SpeechAnalyzer: designed for long meetings and distant speakers.
    private static func withSpeechAnalyzer(_ url: URL, locale: Locale) async throws -> [SpeakerDiarization.Piece] {
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task {
            var pieces: [SpeakerDiarization.Piece] = []
            for try await result in transcriber.results where result.isFinal {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let start = result.range.start.seconds
                let end = result.range.end.seconds
                pieces.append(SpeakerDiarization.Piece(text: text,
                                                       start: start.isFinite ? start : 0,
                                                       end: end.isFinite ? end : 0))
            }
            return pieces
        }
        let file = try AVAudioFile(forReading: url)
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            try await analyzer.cancelAndFinishNow()
        }
        return try await collector.value
    }

    /// Fallback for languages SpeechAnalyzer does not cover on this device.
    private static func withLegacyRecognizer(_ url: URL, language: String) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)), recognizer.isAvailable else {
            throw Failure.unsupported
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.addsPunctuation = true
        request.shouldReportPartialResults = false
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        final class Once: @unchecked Sendable { var done = false }
        let once = Once()
        return try await withCheckedThrowingContinuation { cont in
            recognizer.recognitionTask(with: request) { result, error in
                guard !once.done else { return }
                if let error { once.done = true; cont.resume(throwing: error); return }
                if let result, result.isFinal {
                    once.done = true
                    cont.resume(returning: result.bestTranscription.formattedString)
                }
            }
        }
    }
}
