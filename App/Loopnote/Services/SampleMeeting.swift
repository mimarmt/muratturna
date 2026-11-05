import AVFoundation
import Foundation
import SwiftData

/// Builds a realistic test meeting without anyone speaking: a short scripted conversation is
/// read by the best installed voice, saved as a recording,
/// and processed exactly like a real meeting (transcript, speakers, minutes).
enum SampleMeeting {
    struct Line: Sendable {
        let speaker: Int
        let text: String
    }

    static func script(for language: String) -> [Line] {
        if language.hasPrefix("tr") {
            return [
                Line(speaker: 0, text: "Günaydın. Bugün Yalova termal SPA otelinin son durumunu konuşalım."),
                Line(speaker: 1, text: "Kaba inşaatta bodrum katlar bitti. Türk hamamı bölümünün kalıpları bu hafta kuruluyor."),
                Line(speaker: 0, text: "Belediyeden ruhsat eki için hâlâ cevap bekliyoruz. Bu konuyu Ömer takip etsin."),
                Line(speaker: 1, text: "Tamam. Ömer perşembe günü belediyeye gidip eksik evrakları teslim edecek."),
                Line(speaker: 0, text: "VIP odaların cephe görsellerini cuma gününe kadar Murat hazırlayacak."),
                Line(speaker: 1, text: "Beton siparişini yüzde on artırmaya karar verdik, çelik fiyatlarını da yeniden soracağız."),
                Line(speaker: 0, text: "Toplantı salonlarının yerleşimi şimdilik değişmiyor. Bir sonraki toplantı gelecek pazartesi saat onda.")
            ]
        }
        if language.hasPrefix("de") {
            return [
                Line(speaker: 0, text: "Guten Morgen. Wir besprechen heute den Stand des Thermalhotels in Yalova."),
                Line(speaker: 1, text: "Der Rohbau der Untergeschosse ist fertig. Die Schalung für das Hamam wird diese Woche gestellt."),
                Line(speaker: 0, text: "Die Baugenehmigung steht noch aus. Ömer übernimmt das und geht am Donnerstag zum Bauamt."),
                Line(speaker: 1, text: "Murat liefert die Fassadenrenderings der VIP-Zimmer bis Freitag."),
                Line(speaker: 0, text: "Wir erhöhen die Betonbestellung um zehn Prozent. Nächstes Treffen ist Montag um zehn Uhr.")
            ]
        }
        return [
            Line(speaker: 0, text: "Good morning. Let's review the Yalova thermal spa hotel today."),
            Line(speaker: 1, text: "The basement structure is finished. The formwork for the Turkish bath goes up this week."),
            Line(speaker: 0, text: "We are still waiting for the permit. Ömer will take the missing documents to the municipality on Thursday."),
            Line(speaker: 1, text: "Murat will prepare the facade renders of the VIP rooms by Friday."),
            Line(speaker: 0, text: "We decided to increase the concrete order by ten percent. Next meeting is Monday at ten.")
        ]
    }

    /// Creates the recording and the meeting, then starts processing. Returns the meeting.
    @MainActor
    static func create(in context: ModelContext) async throws -> Meeting {
        Trace.log("sample: start")
        let language = LanguageDetector.fallback
        // One voice: voices can differ in sample rate, and the recording must be one format.
        let ids = [VoiceCatalog.voice(for: language, allowPersonal: false)?.identifier].compactMap { $0 }
        Trace.log("sample: voice chosen (\(ids.first ?? "default"))")
        let lines = script(for: language)
        let fileName = "sample-\(UUID().uuidString).caf"
        let url = Meeting.directory.appendingPathComponent(fileName)
        let duration = try await render(lines, voiceIDs: ids, language: language, to: url)
        Trace.log("sample: audio ready, \(Int(duration)) s")

        let meeting = Meeting(title: String(localized: "Sample meeting"), audioFileName: fileName,
                              duration: duration, language: language)
        context.insert(meeting)
        try? context.save()
        AppRouter.shared.openMeeting(meeting.id)
        MeetingProcessor.shared.start(meeting)
        Trace.log("sample: processing started")
        return meeting
    }

    /// Speaks every line into one PCM file, with a short pause between speakers.
    nonisolated private static func render(_ lines: [Line], voiceIDs: [String], language: String,
                                           to url: URL) async throws -> Double {
        let output = OutputFile(url: url)
        for (n, line) in lines.enumerated() {
            Trace.log("sample: line \(n + 1)/\(lines.count)")
            let id = voiceIDs.isEmpty ? nil : voiceIDs[line.speaker % voiceIDs.count]
            try await speak(line.text, voiceID: id, language: language, into: output)
        }
        return output.close()
    }

    nonisolated private static func speak(_ text: String, voiceID: String?, language: String,
                                          into output: OutputFile) async throws {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voiceID.flatMap(AVSpeechSynthesisVoice.init(identifier:))
            ?? AVSpeechSynthesisVoice(language: language)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.postUtteranceDelay = 0.6
        try await SpeechWriter.write(utterance) { pcm in try output.append(pcm) }
        output.appendSilence(seconds: 0.5)
    }
}

/// Thread-safe PCM writer shared by all lines of the sample meeting.
private final class OutputFile: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var format: AVAudioFormat?
    private var frames: AVAudioFramePosition = 0

    init(url: URL) { self.url = url }

    func append(_ pcm: AVAudioPCMBuffer) throws {
        lock.lock(); defer { lock.unlock() }
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
                                   commonFormat: pcm.format.commonFormat, interleaved: pcm.format.isInterleaved)
            format = pcm.format
        }
        // Voices can differ in sample rate; a line in another format is skipped rather than garbled.
        guard pcm.format == format else { return }
        try file?.write(from: pcm)
        frames += AVAudioFramePosition(pcm.frameLength)
    }

    func appendSilence(seconds: Double) {
        lock.lock(); defer { lock.unlock() }
        guard let format, let file else { return }
        let count = AVAudioFrameCount(format.sampleRate * seconds)
        guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { return }
        silence.frameLength = count
        try? file.write(from: silence)
        frames += AVAudioFramePosition(count)
    }

    /// Closes the file and returns its length in seconds.
    func close() -> Double {
        lock.lock(); defer { lock.unlock() }
        let seconds = format.map { Double(frames) / $0.sampleRate } ?? 0
        file = nil
        return seconds
    }
}
