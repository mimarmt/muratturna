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

    private func load() async throws -> WhisperKit {
        if let pipe { return pipe }
        let config = WhisperKitConfig(model: Self.model, verbose: false, prewarm: true)
        let p = try await WhisperKit(config)
        pipe = p
        return p
    }

    /// Transcribes a file into time-stamped pieces in the given language ("tr", "en", "de").
    func transcribe(_ url: URL, language: String) async throws -> [SpeakerDiarization.Piece] {
        let pipe = try await load()
        let code = String(language.prefix(2))
        let options = DecodingOptions(task: .transcribe, language: code, skipSpecialTokens: true,
                                      chunkingStrategy: .vad)
        let results = try await pipe.transcribe(
            audioPath: url.path,
            audioInputOptions: AudioInputOptions(audioLoadingMode: .incremental),
            decodeOptions: options)
        return results.flatMap(\.segments).compactMap { segment in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return SpeakerDiarization.Piece(text: text, start: Double(segment.start), end: Double(segment.end))
        }
    }
}
