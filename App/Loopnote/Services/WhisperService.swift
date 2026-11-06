import Foundation
import WhisperKit

/// High-accuracy, fully on-device transcription with Whisper large-v3 (≈600 MB, downloaded once).
actor WhisperService {
    static let shared = WhisperService()
    static let model = "large-v3-v20240930_626MB"
    static let readyKey = "whisper.ready"

    private var pipe: WhisperKit?

    /// True once the model has been downloaded and loaded successfully at least once.
    nonisolated static var isReady: Bool { UserDefaults.standard.bool(forKey: readyKey) }

    /// Downloads (first time) and loads the model.
    func prepare() async throws {
        _ = try await load()
        UserDefaults.standard.set(true, forKey: Self.readyKey)
    }

    func unload() {
        pipe = nil
    }

    private var isLoading = false

    /// Loads the model once. Calls that arrive while a load is running wait for it instead of
    /// starting a second 600 MB load (actor methods can interleave at each `await`).
    private func load() async throws -> WhisperKit {
        while isLoading {
            try await Task.sleep(for: .milliseconds(250))
        }
        if let pipe { return pipe }
        isLoading = true
        defer { isLoading = false }
        Trace.log("whisper: loading model")
        let config = WhisperKitConfig(model: Self.model, verbose: false, prewarm: true)
        let p = try await WhisperKit(config)
        pipe = p
        Trace.log("whisper: model ready")
        return p
    }

    struct NotLoaded: Error {}

    /// Returns the loaded model, waiting at most `seconds` for a load in progress (or one it
    /// starts). The first load after installing an update can take minutes while iOS compiles
    /// the model; a meeting should not wait for that, so the caller falls back to Apple's
    /// on-device transcription and Whisper is ready for the next meeting.
    private func model(within seconds: Double) async throws -> WhisperKit {
        if let pipe { return pipe }
        if !isLoading { Task { try? await self.prepare() } }
        let deadline = Date.now.addingTimeInterval(seconds)
        while Date.now < deadline {
            try await Task.sleep(for: .milliseconds(250))
            if let pipe { return pipe }
        }
        Trace.log("whisper: model not ready after \(Int(seconds)) s, using Apple transcription")
        throw NotLoaded()
    }

    /// Transcribes a file into time-stamped pieces in the given language ("tr", "en", "de").
    func transcribe(_ url: URL, language: String, vocabulary: [String] = [],
                    waitForModel: Double = 20) async throws -> [SpeakerDiarization.Piece] {
        let pipe = try await model(within: waitForModel)
        let code = String(language.prefix(2))
        var options = DecodingOptions(task: .transcribe, language: code, skipSpecialTokens: true,
                                      chunkingStrategy: .vad)
        // Names and terms Whisper should spell as written (e.g. "Claude", not "Cloud").
        let prompt = vocabulary.joined(separator: ", ")
        if !prompt.isEmpty, let tokenizer = pipe.tokenizer {
            options.promptTokens = tokenizer.encode(text: " " + prompt)
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            options.usePrefillPrompt = true
            Trace.log("whisper: \(vocabulary.count) custom words")
        }
        Trace.log("whisper: transcribing")
        let results = try await pipe.transcribe(
            audioPath: url.path,
            audioInputOptions: AudioInputOptions(audioLoadingMode: .incremental),
            decodeOptions: options)
        Trace.log("whisper: \(results.count) results")
        return results.flatMap(\.segments).compactMap { segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return SpeakerDiarization.Piece(text: text, start: Double(segment.start), end: Double(segment.end))
        }
    }
}
