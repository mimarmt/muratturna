import AVFoundation
import Observation
import BackgroundTasks
import Foundation
import FoundationModels
import Speech
import SwiftData
import UIKit

/// Turns a recorded meeting into a transcript and AI minutes.
@MainActor
@Observable
final class MeetingProcessor {
    static let shared = MeetingProcessor()
    static let taskPrefix = "com.muratturna.loopnote.meeting."

    /// Meetings being processed right now (so resume never runs one twice).
    private var inFlight = Set<UUID>()

    enum Stage: Sendable { case downloadingModel, transcribing, speakers, summarizing }
    /// What the current meeting is doing, shown on its minutes screen.
    private(set) var stage: Stage = .transcribing
    private var currentTask: BGContinuedProcessingTask?

    func setStage(_ s: Stage) {
        stage = s
        let text: String = switch s {
        case .downloadingModel: String(localized: "Downloading the speech model…")
        case .transcribing: String(localized: "Transcribing…")
        case .speakers: String(localized: "Separating speakers…")
        case .summarizing: String(localized: "Finding decisions and action items…")
        }
        currentTask?.updateTitle(String(localized: "Writing meeting minutes"), subtitle: text)
    }

    /// Fetches speech and speaker models in the background so the first meeting is fast.
    func prewarm() {
        let language = LanguageDetector.fallback
        Task.detached(priority: .background) {
            await MeetingTranscription.prewarm(language: language)
            await SpeakerDiarization.prewarm()
        }
    }

    /// Starts processing as a continued background task (iOS 26): it keeps running when the
    /// app goes to the background, with progress shown by the system. Falls back to a
    /// foreground task if the system declines the request.
    func start(_ meeting: Meeting) {
        let id = meeting.id
        guard !inFlight.contains(id) else { return }
        let identifier = Self.taskPrefix + id.uuidString.replacingOccurrences(of: "-", with: "")
        if Self.registerBackgroundTask(identifier: identifier, meetingID: id) {
            let request = BGContinuedProcessingTaskRequest(
                identifier: identifier,
                title: String(localized: "Writing meeting minutes"),
                subtitle: String(localized: "Transcribing…"))
            request.strategy = .fail
            if (try? BGTaskScheduler.shared.submit(request)) != nil { return }
        }
        Task { _ = await run(id: id, task: nil) }
    }

    /// The launch handler runs on a background queue, so it must not be created in a
    /// main-actor context (Swift 6 would trap when iOS calls it).
    nonisolated private static func registerBackgroundTask(identifier: String, meetingID: UUID) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let task = task as? BGContinuedProcessingTask else { return }
            nonisolated(unsafe) let bgTask = task
            bgTask.expirationHandler = { bgTask.progress.cancel() }
            Task { @MainActor in
                let ok = await MeetingProcessor.shared.run(id: meetingID, task: bgTask)
                bgTask.setTaskCompleted(success: ok)
            }
        }
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

    func run(id: UUID, task: BGContinuedProcessingTask?) async -> Bool {
        guard !inFlight.contains(id) else { return false }
        let context = Persistence.container.mainContext
        guard let meeting = try? context.fetch(FetchDescriptor<Meeting>(predicate: #Predicate { $0.id == id })).first
        else { return false }
        inFlight.insert(id)
        currentTask = task
        defer { inFlight.remove(id); currentTask = nil }
        task?.progress.totalUnitCount = 100
        task?.progress.completedUnitCount = 5
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
                let duration = meeting.duration
                meeting.transcript = try await withTimeout(seconds: max(120, duration * 2)) {
                    try await MeetingTranscription.transcribe(url, language: language, duration: duration)
                }
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
        setStage(.summarizing)
        try? context.save()
        let language = LanguageDetector.speechLanguage(for: meeting.transcript)
        meeting.language = language
        let transcript = meeting.transcript
        let minutes = (try? await withTimeout(seconds: 90) {
            await MeetingSummarizer.minutes(for: transcript, language: language)
        }) ?? MeetingSummarizer.fallback(transcript)
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

struct TimeoutError: LocalizedError {
    var errorDescription: String? {
        String(localized: "Processing took too long. Tap Try again.")
    }
}

/// Runs `work`, failing with `TimeoutError` if it takes longer than `seconds`.
func withTimeout<T: Sendable>(seconds: Double, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw TimeoutError()
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw TimeoutError() }
        return first
    }
}

/// Long-form, on-device transcription of an audio file.
enum MeetingTranscription {
    enum Failure: LocalizedError {
        case unsupported
        var errorDescription: String? { String(localized: "Speech recognition isn’t available for this language on this device.") }
    }

    static func transcribe(_ url: URL, language: String, duration: Double) async throws -> String {
        // High-accuracy Whisper when the user turned it on and the model is installed.
        if UserDefaults.standard.bool(forKey: AppSettings.Key.useWhisper), WhisperService.isReady {
            await MeetingProcessor.shared.setStage(.transcribing)
            async let spans = SpeakerDiarization.speakers(
                in: url, timeout: duration >= 45 ? min(60, max(20, duration * 0.5)) : 0)
            if let pieces = try? await WhisperService.shared.transcribe(url, language: language), !pieces.isEmpty {
                if duration >= 45 { await MeetingProcessor.shared.setStage(.speakers) }
                return SpeakerDiarization.label(pieces, with: await spans)
            }
            _ = await spans
        }
        if let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) {
            // Diarization is a bonus: skipped for short clips, time-limited for long ones,
            // and never allowed to hold up the transcript.
            guard duration >= 45 else {
                let pieces = try await withSpeechAnalyzer(url, locale: locale)
                return SpeakerDiarization.label(pieces, with: [])
            }
            let limit = min(60, max(20, duration * 0.5))
            async let spans = SpeakerDiarization.speakers(in: url, timeout: limit)
            let pieces = try await withSpeechAnalyzer(url, locale: locale)
            await MeetingProcessor.shared.setStage(.speakers)
            return SpeakerDiarization.label(pieces, with: await spans)
        }
        // Languages the long-form model lacks (e.g. Turkish): the on-device dictation model.
        if let locale = await dictationLocale(for: language) {
            guard duration >= 45 else {
                let pieces = try await withDictation(url, locale: locale)
                return SpeakerDiarization.label(pieces, with: [])
            }
            let limit = min(60, max(20, duration * 0.5))
            async let spans = SpeakerDiarization.speakers(in: url, timeout: limit)
            let pieces = try await withDictation(url, locale: locale)
            await MeetingProcessor.shared.setStage(.speakers)
            return SpeakerDiarization.label(pieces, with: await spans)
        }
        return try await withLegacyRecognizer(url, language: language)
    }

    /// iOS 26 SpeechAnalyzer: designed for long meetings and distant speakers.
    /// Downloads the speech model for a language ahead of the first meeting.
    static func prewarm(language: String) async {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) else { return }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        if let request = try? await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try? await request.downloadAndInstall()
        }
    }

    private static func withSpeechAnalyzer(_ url: URL, locale: Locale) async throws -> [SpeakerDiarization.Piece] {
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            await MeetingProcessor.shared.setStage(.downloadingModel)
            try await request.downloadAndInstall()
        }
        await MeetingProcessor.shared.setStage(.transcribing)
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

    private static func dictationLocale(for language: String) async -> Locale? {
        let code = Locale(identifier: language).language.languageCode
        let all = await DictationTranscriber.supportedLocales
        return all.first { $0.identifier(.bcp47) == language }
            ?? all.first { $0.language.languageCode == code }
    }

    private static func withDictation(_ url: URL, locale: Locale) async throws -> [SpeakerDiarization.Piece] {
        let transcriber = DictationTranscriber(locale: locale, preset: .longDictation)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            await MeetingProcessor.shared.setStage(.downloadingModel)
            try await request.downloadAndInstall()
        }
        await MeetingProcessor.shared.setStage(.transcribing)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task {
            var pieces: [SpeakerDiarization.Piece] = []
            for try await result in transcriber.results where result.isFinal {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let start = result.range.start.seconds, end = result.range.end.seconds
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

    /// Last resort: the classic recognizer, fed 45-second slices so nothing past the
    /// first minute is lost.
    private static func withLegacyRecognizer(_ url: URL, language: String) async throws -> String {
        var parts: [String] = []
        for slice in try slices(of: url, seconds: 45) {
            defer { try? FileManager.default.removeItem(at: slice) }
            let text = (try? await recognizeSlice(slice, language: language)) ?? ""
            if !text.isBlank { parts.append(text) }
        }
        guard !parts.isEmpty else { throw Failure.unsupported }
        return parts.joined(separator: "\n\n")
    }

    private static func slices(of url: URL, seconds: Double) throws -> [URL] {
        let source = try AVAudioFile(forReading: url)
        let format = source.processingFormat
        let framesPerSlice = AVAudioFrameCount(format.sampleRate * seconds)
        var urls: [URL] = []
        while source.framePosition < source.length {
            let count = min(framesPerSlice, AVAudioFrameCount(source.length - source.framePosition))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { break }
            try source.read(into: buffer, frameCount: count)
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("slice-\(UUID().uuidString).caf")
            let file = try AVAudioFile(forWriting: out, settings: format.settings,
                                       commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            try file.write(from: buffer)
            urls.append(out)
        }
        return urls
    }

    private static func recognizeSlice(_ url: URL, language: String) async throws -> String {
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
