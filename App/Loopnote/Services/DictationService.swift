import AVFoundation
import Observation
import Speech

/// Live, on-device dictation for note entry.
@MainActor
@Observable
final class DictationService {
    var transcript = ""
    var isRecording = false
    var errorMessage: String?

    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func toggle(language: String) async {
        if isRecording { stop() } else { await start(language: language) }
    }

    func start(language: String) async {
        errorMessage = nil
        guard await Self.authorize() else {
            errorMessage = String(localized: "Microphone or speech access is turned off. You can allow it in Settings.")
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)) ?? SFSpeechRecognizer(),
              recognizer.isAvailable else {
            errorMessage = String(localized: "Speech recognition isn’t available right now.")
            return
        }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }

        let engine = AVAudioEngine()
        do {
            try Self.installTap(on: engine, feeding: request)
            engine.prepare()
            try engine.start()
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        let prefix = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        task = Self.recognize(with: recognizer, request: request) { [weak self] text, isFinal in
            guard let self else { return }
            if let text { self.transcript = prefix.isEmpty ? text : prefix + " " + text }
            if isFinal { self.stop() }
        }
        self.engine = engine
        self.request = request
        isRecording = true
    }

    func stop() {
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.finish()
        engine = nil
        request = nil
        task = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Non-isolated helpers (callbacks arrive on audio / speech queues)

    nonisolated private static func installTap(on engine: AVAudioEngine,
                                               feeding request: SFSpeechAudioBufferRecognitionRequest) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        nonisolated(unsafe) let request = request
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
    }

    nonisolated private static func recognize(
        with recognizer: SFSpeechRecognizer,
        request: SFSpeechAudioBufferRecognitionRequest,
        update: @escaping @MainActor @Sendable (String?, Bool) -> Void
    ) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = (result?.isFinal ?? false) || error != nil
            Task { @MainActor in update(text, isFinal) }
        }
    }

    nonisolated static func authorize() async -> Bool {
        let speech = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }
}
