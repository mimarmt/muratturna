import AVFoundation
import Foundation
import FoundationModels
import Speech
import SwiftData
import UIKit

/// Turns a recorded meeting into a transcript and AI minutes.
@MainActor
final class MeetingProcessor {
    static let shared = MeetingProcessor()

    func process(_ meeting: Meeting) async {
        guard let url = meeting.audioURL else { return }
        let context = Persistence.container.mainContext
        let bg = UIApplication.shared.beginBackgroundTask(withName: "meeting") {}
        defer { UIApplication.shared.endBackgroundTask(bg) }

        if meeting.transcript.isEmpty {
            meeting.status = .transcribing
            try? context.save()
            do {
                let language = meeting.language ?? LanguageDetector.fallback
                meeting.transcript = try await MeetingTranscription.transcribe(url, language: language)
            } catch {
                meeting.status = .failed
                meeting.errorMessage = error.localizedDescription
                try? context.save()
                return
            }
        }
        guard !meeting.transcript.isBlank else {
            meeting.status = .failed
            meeting.errorMessage = String(localized: "No speech was found in the recording.")
            try? context.save()
            return
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
    }
}

/// Long-form, on-device transcription of an audio file.
enum MeetingTranscription {
    enum Failure: LocalizedError {
        case unsupported
        var errorDescription: String? { String(localized: "Speech recognition isn’t available for this language on this device.") }
    }

    static func transcribe(_ url: URL, language: String) async throws -> String {
        if let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) {
            async let spans = SpeakerDiarization.speakers(in: url)
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
