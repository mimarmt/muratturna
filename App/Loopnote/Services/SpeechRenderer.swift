import AVFoundation

/// Renders text to an audio file that iOS can play as a notification sound.
///
/// Notification sounds must live in `Library/Sounds`, be Linear PCM/aiff/caf and last at most 30 seconds.
@MainActor
final class SpeechRenderer {
    static let shared = SpeechRenderer()
    nonisolated static let maxSeconds: Double = 29
    private static let isUITest = ProcessInfo.processInfo.arguments.contains("-uitest")

    private let synthesizer = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?

    static var soundsDirectory: URL {
        let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sounds", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Returns the file name (inside Library/Sounds) for the spoken text, rendering it if needed.
    func soundFile(for text: String, language: String) async -> String? {
        // UI smoke tests run on a bare simulator whose speech service is slow to wake; they check
        // the screens, not the audio, so notifications use the default sound there.
        if Self.isUITest { return nil }
        if let eleven = await elevenLabsFile(for: text) { return eleven }
        return await appleSoundFile(for: text, language: language)
    }

    /// Renders with ElevenLabs when it is enabled; nil means "use the Apple voice".
    private func elevenLabsFile(for text: String) async -> String? {
        guard let voice = AppSettings.elevenVoice else { return nil }
        let name = "ln-\(Self.stableHash("el|\(voice.id)|\(voice.model)|\(text)")).wav"
        let url = Self.soundsDirectory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) { return name }
        do {
            try await ElevenLabsClient.render(text: text, voiceID: voice.id, model: voice.model, to: url)
            AppSettings.elevenLastError = nil
            return name
        } catch {
            // Falling back to the Apple voice silently made it look as if ElevenLabs was ignored;
            // keep the reason so Settings can show it, and log it for the step log.
            try? FileManager.default.removeItem(at: url)
            AppSettings.elevenLastError = error.localizedDescription
            Trace.log("eleven: failed, Apple voice used – \(error.localizedDescription)")
            return nil
        }
    }

    private func appleSoundFile(for text: String, language: String) async -> String? {
        let personal = AppSettings.usePersonalVoice
        let rate = AppSettings.speechRate
        let directory = Self.soundsDirectory
        // Listing voices and starting the synthesizer can block for seconds (first use, voice
        // downloads), so all of it runs off the main thread and the UI stays responsive.
        return await Task.detached(priority: .utility) { () -> String? in
            let voiceID = VoiceCatalog.voice(for: language, allowPersonal: personal)?.identifier
            let key = "\(voiceID ?? language)|\(rate)|\(text)"
            let name = "ln-\(SpeechRenderer.stableHash(key)).caf"
            let url = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { return name }
            do {
                try await SpeechRenderer.render(text: text, voiceIdentifier: voiceID, language: language,
                                                rate: rate, to: url)
                return name
            } catch {
                try? FileManager.default.removeItem(at: url)
                return nil
            }
        }.value
    }

    /// Speaks immediately (used by "Listen again" and previews).
    func speakNow(_ text: String, language: String) {
        Task {
            if let name = await elevenLabsFile(for: text) {
                play(Self.soundsDirectory.appendingPathComponent(name))
            } else {
                speakWithApple(text, language: language)
            }
        }
    }

    /// Previews a specific ElevenLabs voice (used by the voice picker).
    func previewElevenLabs(_ text: String, voiceID: String, model: String) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("preview-\(voiceID)-\(model).wav")
        try await ElevenLabsClient.render(text: text, voiceID: voiceID, model: model, to: url)
        play(url)
    }

    private func play(_ url: URL) {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        synthesizer.stopSpeaking(at: .immediate)
        player = try? AVAudioPlayer(contentsOf: url)
        player?.play()
    }

    private func speakWithApple(_ text: String, language: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = VoiceCatalog.voice(for: language, allowPersonal: AppSettings.usePersonalVoice)
        utterance.rate = AppSettings.speechRate
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer.speak(utterance)
    }

    /// Removes rendered sounds that are no longer referenced.
    func pruneSounds(keeping names: Set<String>) {
        let dir = Self.soundsDirectory
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for f in files where f.hasPrefix("ln-") && !names.contains(f) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
        }
    }

    /// Runs off the main actor: the synthesizer calls back on its own queue.
    nonisolated private static func render(text: String, voiceIdentifier: String?, language: String,
                                           rate: Float, to url: URL) async throws {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voiceIdentifier.flatMap(AVSpeechSynthesisVoice.init(identifier:))
            ?? AVSpeechSynthesisVoice(language: language)
        utterance.rate = rate
        utterance.preUtteranceDelay = 0.25
        utterance.postUtteranceDelay = 0.2
        let state = WriteState()
        try await SpeechWriter.write(utterance) { pcm in try state.write(pcm, to: url) }
        state.finish {}
    }

    /// FNV-1a; stable across launches (unlike `Hasher`).
    nonisolated static func stableHash(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }
}

/// Mutable render state shared with the synthesizer's callback queue (accessed serially).
private final class WriteState: @unchecked Sendable {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var frames: AVAudioFramePosition = 0
    private var finished = false

    func write(_ pcm: AVAudioPCMBuffer, to url: URL) throws {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        if file == nil {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: pcm.format.sampleRate,
                AVNumberOfChannelsKey: pcm.format.channelCount,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ]
            file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: pcm.format.commonFormat,
                                   interleaved: pcm.format.isInterleaved)
        }
        let limit = AVAudioFramePosition(pcm.format.sampleRate * SpeechRenderer.maxSeconds)
        if frames + AVAudioFramePosition(pcm.frameLength) <= limit {
            try file?.write(from: pcm)
            frames += AVAudioFramePosition(pcm.frameLength)
        }
    }

    /// Runs `resume` exactly once, after closing the file.
    func finish(_ resume: () -> Void) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        file = nil
        lock.unlock()
        resume()
    }
}
