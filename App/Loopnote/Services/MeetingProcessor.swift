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
    nonisolated static let taskPrefix = "com.muratturna.loopnote.meeting."

    /// Meetings being processed right now (so resume never runs one twice).
    private var inFlight = Set<UUID>()

    enum Stage: Sendable { case downloadingModel, transcribing, speakers, summarizing }
    /// What the current meeting is doing, shown on its minutes screen.
    private(set) var stage: Stage = .transcribing
    private var currentTask: BGContinuedProcessingTask?

    func setStage(_ s: Stage) {
        Trace.log("processor: stage \(s)")
        stage = s
        let text: String = switch s {
        case .downloadingModel: String(localized: "Downloading the speech model…")
        case .transcribing: String(localized: "Transcribing…")
        case .speakers: String(localized: "Separating speakers…")
        case .summarizing: String(localized: "Finding decisions and action items…")
        }
        currentTask?.updateTitle(String(localized: "Writing meeting minutes"), subtitle: text)
        progressUnits = switch s {
        case .downloadingModel: 5
        case .transcribing: 10
        case .speakers: 50
        case .summarizing: 70
        }
        currentTask?.progress.completedUnitCount = progressUnits
    }

    private var progressUnits: Int64 = 5

    /// Asks iOS to keep the processing going in the background, with its progress on the Lock
    /// Screen (BGContinuedProcessingTask). Registering and submitting run off the main thread,
    /// and the processing itself already runs in the app: if iOS declines, nothing changes.
    nonisolated static func requestContinuedProcessing(for id: UUID) {
        let identifier = taskPrefix + id.uuidString.replacingOccurrences(of: "-", with: "")
        let title = String(localized: "Writing meeting minutes")
        let subtitle = String(localized: "Transcribing…")
        Task.detached(priority: .utility) {
            let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
                guard let task = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                nonisolated(unsafe) let bgTask = task
                Task { @MainActor in await MeetingProcessor.shared.attach(bgTask, to: id) }
            }
            guard registered else {
                Trace.log("processor: background processing not registered")
                return
            }
            let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
            request.strategy = .fail
            do {
                try BGTaskScheduler.shared.submit(request)
                Trace.log("processor: background processing requested")
            } catch {
                Trace.log("processor: background processing declined (\(error.localizedDescription))")
            }
        }
    }

    /// Keeps the system's continued-processing task open while the meeting is processed, so
    /// iOS lets Loopnote finish in the background and shows the progress.
    func attach(_ task: BGContinuedProcessingTask, to id: UUID) async {
        Trace.log("processor: background processing started")
        currentTask = task
        task.progress.totalUnitCount = 100
        task.progress.completedUnitCount = progressUnits
        final class Once: @unchecked Sendable { var done = false }
        let once = Once()
        nonisolated(unsafe) let expiring = task
        task.expirationHandler = {
            // iOS needs the task completed on expiry; the meeting resumes when Loopnote opens.
            Trace.log("processor: background processing expired")
            DispatchQueue.main.async {
                guard !once.done else { return }
                once.done = true
                expiring.setTaskCompleted(success: false)
            }
        }
        var waited = 0
        while !inFlight.contains(id) && waited < 40 {
            try? await Task.sleep(for: .milliseconds(250))
            waited += 1
        }
        while inFlight.contains(id) {
            try? await Task.sleep(for: .seconds(1))
        }
        let context = Persistence.container.mainContext
        let meeting = try? context.fetch(FetchDescriptor<Meeting>(predicate: #Predicate { $0.id == id })).first
        let ok = meeting?.status == .ready
        task.progress.completedUnitCount = 100
        if currentTask === task { currentTask = nil }
        guard !once.done else { return }
        once.done = true
        task.setTaskCompleted(success: ok)
        Trace.log("processor: background processing finished, ok=\(ok)")
    }

    /// Fetches speech and speaker models in the background so the first meeting is fast.
    func prewarm() {
        let language = LanguageDetector.fallback
        Task.detached(priority: .background) {
            await MeetingTranscription.prewarm(language: language)
            await SpeakerDiarization.prewarm()
        }
        prewarmWhisperAfterUpdate()
    }

    /// After each app update iOS compiles the Whisper model again for the Neural Engine, which
    /// can take minutes. Do it once in the background right after the update is opened, so
    /// the next meeting loads the model in seconds. The model is unloaded again afterwards.
    private func prewarmWhisperAfterUpdate() {
        guard UserDefaults.standard.bool(forKey: AppSettings.Key.useWhisper), WhisperService.isReady else { return }
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        let key = "whisper.compiledForBuild"
        guard UserDefaults.standard.string(forKey: key) != build else { return }
        whisperPreparing = true
        // Extra time so the compile goes on for a while after the app is closed. The
        // expiration handler must end the task, or iOS terminates the app.
        let box = BackgroundTimeBox()
        box.id = UIApplication.shared.beginBackgroundTask(withName: "whisper-compile") {
            Trace.log("whisper: background time ran out; compile continues when Loopnote opens")
            box.end()
        }
        Task.detached(priority: .utility) {
            Trace.log("whisper: compiling model for this version")
            do {
                try await WhisperService.shared.prepare()
                UserDefaults.standard.set(build, forKey: key)
                Trace.log("whisper: compiled for build \(build)")
                // Keep it loaded if a meeting is being recorded or processed; otherwise free the memory.
                let busy = await MeetingProcessor.shared.isBusy
                if !busy { await WhisperService.shared.unload() }
            } catch {
                Trace.log("whisper: compile failed")
            }
            await MainActor.run {
                MeetingProcessor.shared.whisperPreparing = false
                box.end()
            }
        }
    }

    /// Words Whisper should spell as written: built-in names, project names and the user's list.
    static func vocabulary(in context: ModelContext) -> [String] {
        var words = ["Claude", "Loopnote"]
        let projects = (try? context.fetch(FetchDescriptor<Project>())) ?? []
        words += projects.map(\.name)
        let custom = UserDefaults.standard.string(forKey: AppSettings.Key.customWords) ?? ""
        words += custom.split(whereSeparator: { $0 == "," || $0 == "\n" }).map(String.init)
        var seen = Set<String>()
        return words.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
            .prefix(40).map { $0 }
    }

    /// True while the Whisper model is being prepared after an update (shown in Settings).
    private(set) var whisperPreparing = false

    /// True while a meeting is recorded or processed (then a loaded Whisper model is kept).
    var isBusy: Bool { !inFlight.isEmpty || AppRouter.shared.showMeetingRecorder }

    /// Starts processing right away in the app, and asks iOS to let it continue in the
    /// background (continued processing, with progress on the Lock Screen).
    ///
    /// The background request is registered and submitted off the main thread: done on the
    /// main thread at "Finish" it once froze the app on iOS 27.
    func start(_ meeting: Meeting) {
        let id = meeting.id
        guard !inFlight.contains(id) else { return }
        Task {
            // The expiration handler must end the task, or iOS terminates the app.
            let box = BackgroundTimeBox()
            box.id = UIApplication.shared.beginBackgroundTask(withName: "meeting-minutes") {
                Trace.log("processor: background time ran out; continues when Loopnote opens")
                box.end()
            }
            Self.requestContinuedProcessing(for: id)
            _ = await run(id: id, task: nil)
            box.end()
        }
    }

    /// Restarts meetings left unfinished (app suspended or killed while processing).
    func resumePending() {
        let context = Persistence.container.mainContext
        let pending = (try? context.fetch(FetchDescriptor<Meeting>())) ?? []
        for m in pending where [.recorded, .transcribing, .summarizing].contains(m.status) && !inFlight.contains(m.id) {
            // A meeting whose processing ended with the app terminating twice is not retried
            // automatically: that would close the app on every launch. The user can retry.
            if Self.attempts(for: m.id) >= 2 {
                m.status = .failed
                m.errorMessage = String(localized: "Processing stopped unexpectedly. Tap Try again.")
                Self.clearAttempts(for: m.id)
                try? context.save()
                continue
            }
            Task { _ = await run(id: m.id, task: nil) }
        }
    }

    // MARK: Crash-loop guard

    private static func attemptsKey(_ id: UUID) -> String { "meeting.attempts." + id.uuidString }
    static func attempts(for id: UUID) -> Int { UserDefaults.standard.integer(forKey: attemptsKey(id)) }
    static func clearAttempts(for id: UUID) { UserDefaults.standard.removeObject(forKey: attemptsKey(id)) }
    private static func countAttempt(for id: UUID) {
        UserDefaults.standard.set(attempts(for: id) + 1, forKey: attemptsKey(id))
    }

    func isProcessing(_ id: UUID) -> Bool { inFlight.contains(id) }

    func run(id: UUID, task: BGContinuedProcessingTask?) async -> Bool {
        guard !inFlight.contains(id) else { return false }
        let context = Persistence.container.mainContext
        guard let meeting = try? context.fetch(FetchDescriptor<Meeting>(predicate: #Predicate { $0.id == id })).first
        else { return false }
        inFlight.insert(id)
        if let task { currentTask = task }
        // Counted before the work and cleared after it: a count left behind means the app
        // was terminated while processing this meeting.
        Self.countAttempt(for: id)
        Trace.log("processor: run (attempt \(Self.attempts(for: id)))")
        defer { inFlight.remove(id); Self.clearAttempts(for: id) }
        task?.progress.totalUnitCount = 100
        task?.progress.completedUnitCount = 5
        let ok = await process(meeting, task: task)
        Trace.log("processor: done, ok=\(ok) status=\(meeting.status.rawValue)")
        return ok
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
                let vocabulary = Self.vocabulary(in: context)
                meeting.transcript = try await withTimeout(seconds: max(120, duration * 2)) {
                    try await MeetingTranscription.transcribe(url, language: language, duration: duration,
                                                              vocabulary: vocabulary)
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
        Trace.log("processor: summarizing \(transcript.count) chars")
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
        Self.clearAttempts(for: meeting.id)
        meeting.status = .recorded
        meeting.errorMessage = nil
        start(meeting)
    }
}

/// Holds a UIKit background-task id so its expiration handler can end it exactly once.
final class BackgroundTimeBox: @unchecked Sendable {
    var id: UIBackgroundTaskIdentifier = .invalid
    func end() {
        let current = id
        id = .invalid
        guard current != .invalid else { return }
        DispatchQueue.main.async { UIApplication.shared.endBackgroundTask(current) }
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

    static func transcribe(_ url: URL, language: String, duration: Double,
                           vocabulary: [String] = []) async throws -> String {
        Trace.log("transcribe: \(language), \(Int(duration)) s")
        // High-accuracy Whisper when the user turned it on and the model is installed.
        if UserDefaults.standard.bool(forKey: AppSettings.Key.useWhisper), WhisperService.isReady {
            await MeetingProcessor.shared.setStage(.transcribing)
            async let spans = SpeakerDiarization.speakers(
                in: url, timeout: duration >= 45 ? min(60, max(20, duration * 0.5)) : 0)
            if let pieces = try? await WhisperService.shared.transcribe(url, language: language, vocabulary: vocabulary), !pieces.isEmpty {
                if duration >= 45 { await MeetingProcessor.shared.setStage(.speakers) }
                return SpeakerDiarization.label(pieces, with: await spans)
            }
            _ = await spans
        }
        if let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) {
            Trace.log("transcribe: SpeechTranscriber \(locale.identifier)")
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
            Trace.log("transcribe: DictationTranscriber \(locale.identifier)")
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
        Trace.log("transcribe: legacy recognizer")
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
        Trace.log("analyzer: reading \(file.length) frames")
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            try await analyzer.cancelAndFinishNow()
        }
        let pieces = try await collector.value
        Trace.log("analyzer: \(pieces.count) pieces")
        return pieces
    }

    private static func dictationLocale(for language: String) async -> Locale? {
        let code = Locale(identifier: language).language.languageCode
        let all = await DictationTranscriber.supportedLocales
        return all.first { $0.identifier(.bcp47) == language }
            ?? all.first { $0.language.languageCode == code }
    }

    private static func withDictation(_ url: URL, locale: Locale) async throws -> [SpeakerDiarization.Piece] {
        let transcriber = DictationTranscriber(locale: locale, preset: .longDictation)
        Trace.log("dictation: checking model")
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
        Trace.log("analyzer: reading \(file.length) frames")
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            try await analyzer.cancelAndFinishNow()
        }
        let pieces = try await collector.value
        Trace.log("analyzer: \(pieces.count) pieces")
        return pieces
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
