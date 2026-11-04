import Foundation

/// ElevenLabs text-to-speech. Only the short spoken title is sent; the result is cached on device
/// as a WAV file that iOS plays as the notification sound.
enum ElevenLabsClient {
    static let keyAccount = "elevenlabs.apikey"
    static let base = URL(string: "https://api.elevenlabs.io/v1")!
    /// 24 kHz raw PCM is available on every ElevenLabs plan.
    static let sampleRate = 24_000

    struct Voice: Decodable, Identifiable, Hashable, Sendable {
        let voice_id: String
        let name: String
        let category: String?
        var id: String { voice_id }
    }

    enum Model: String, CaseIterable, Identifiable, Sendable {
        case multilingualV2 = "eleven_multilingual_v2"
        case v3 = "eleven_v3"
        case flash = "eleven_flash_v2_5"
        var id: String { rawValue }
        var label: String {
            switch self {
            case .multilingualV2: "Multilingual v2"
            case .v3: "Eleven v3"
            case .flash: "Flash v2.5"
            }
        }
    }

    enum Failure: LocalizedError {
        case noKey, http(Int, String)
        var errorDescription: String? {
            switch self {
            case .noKey: String(localized: "Add your ElevenLabs API key first.")
            case .http(let code, let body):
                if body.contains("paid_plan_required") || code == 402 {
                    String(localized: "This voice needs a paid ElevenLabs plan (Starter or higher).")
                } else if code == 401 {
                    String(localized: "The ElevenLabs API key is not valid or lacks permissions.")
                } else if code == 429 || body.contains("quota") {
                    String(localized: "Your ElevenLabs quota is used up for this month.")
                } else {
                    String(localized: "ElevenLabs could not create the voice (error \(code)).")
                }
            }
        }
    }

    static var apiKey: String? { Keychain.get(keyAccount) }

    /// A voice from the public ElevenLabs Voice Library.
    struct SharedVoice: Decodable, Identifiable, Hashable, Sendable {
        let public_owner_id: String
        let voice_id: String
        let name: String
        let gender: String?
        let age: String?
        let accent: String?
        let descriptive: String?
        let use_case: String?
        let preview_url: String?
        var id: String { voice_id }
    }

    /// Native speakers of a language from the Voice Library, most used first.
    static func sharedVoices(language: String) async throws -> [SharedVoice] {
        guard let key = apiKey else { throw Failure.noKey }
        var comps = URLComponents(url: base.appendingPathComponent("shared-voices"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "language", value: language),
                            URLQueryItem(name: "page_size", value: "40"),
                            URLQueryItem(name: "sort", value: "usage_character_count_1y")]
        var req = URLRequest(url: comps.url!)
        req.setValue(key, forHTTPHeaderField: "xi-api-key")
        let (data, resp) = try await URLSession.shared.data(for: req)
        try check(resp, data)
        struct List: Decodable { let voices: [SharedVoice] }
        return try JSONDecoder().decode(List.self, from: data).voices
    }

    /// Adds a Voice Library voice to the user's account and returns its new voice ID.
    static func addSharedVoice(_ v: SharedVoice) async throws -> String {
        guard let key = apiKey else { throw Failure.noKey }
        var req = URLRequest(url: base.appendingPathComponent("voices/add/\(v.public_owner_id)/\(v.voice_id)"))
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "xi-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["new_name": v.name])
        let (data, resp) = try await URLSession.shared.data(for: req)
        try check(resp, data)
        struct Added: Decodable { let voice_id: String }
        return try JSONDecoder().decode(Added.self, from: data).voice_id
    }

    /// "Daniel - Steady Broadcaster" → "Daniel"
    static func shortName(_ name: String) -> String {
        name.components(separatedBy: " - ").first?.trimmingCharacters(in: .whitespaces) ?? name
    }

    static func voices() async throws -> [Voice] {
        guard let key = apiKey else { throw Failure.noKey }
        var req = URLRequest(url: base.appendingPathComponent("voices"))
        req.setValue(key, forHTTPHeaderField: "xi-api-key")
        let (data, resp) = try await URLSession.shared.data(for: req)
        try check(resp, data)
        struct List: Decodable { let voices: [Voice] }
        return try JSONDecoder().decode(List.self, from: data).voices
            .sorted { ($0.category == "cloned" ? 0 : 1, $0.name) < ($1.category == "cloned" ? 0 : 1, $1.name) }
    }

    /// Renders `text` and writes a 16-bit mono WAV file to `url`.
    static func render(text: String, voiceID: String, model: String, to url: URL) async throws {
        guard let key = apiKey else { throw Failure.noKey }
        var comps = URLComponents(url: base.appendingPathComponent("text-to-speech/\(voiceID)"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "output_format", value: "pcm_\(sampleRate)")]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue(key, forHTTPHeaderField: "xi-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "text": text,
            "model_id": model,
            "voice_settings": ["stability": 0.5, "similarity_boost": 0.8, "style": 0.15, "use_speaker_boost": true]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (pcm, resp) = try await URLSession.shared.data(for: req)
        try check(resp, pcm)
        try wav(pcm: pcm, sampleRate: sampleRate).write(to: url, options: .atomic)
    }

    private static func check(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw Failure.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }

    /// Wraps little-endian 16-bit mono PCM in a RIFF/WAVE header.
    static func wav(pcm: Data, sampleRate: Int) -> Data {
        func le32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).littleEndian) { Data($0) } }
        func le16(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(v).littleEndian) { Data($0) } }
        var d = Data("RIFF".utf8)
        d += le32(36 + pcm.count)
        d += Data("WAVEfmt ".utf8)
        d += le32(16) + le16(1) + le16(1) + le32(sampleRate) + le32(sampleRate * 2) + le16(2) + le16(16)
        d += Data("data".utf8) + le32(pcm.count)
        d += pcm
        return d
    }
}
