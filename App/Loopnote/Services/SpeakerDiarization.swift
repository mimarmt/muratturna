import FluidAudio
import Foundation

/// "Who spoke when", fully on device (FluidAudio pyannote + WeSpeaker on the Neural Engine).
enum SpeakerDiarization {
    struct Span: Sendable {
        let speaker: String
        let start: Double
        let end: Double
    }

    /// Returns speaker turns, or an empty array when diarization is unavailable.
    /// Models (~30 MB) are downloaded once on first use.
    static func speakers(in url: URL) async -> [Span] {
        do {
            let manager = OfflineDiarizerManager(config: .default)
            try await manager.prepareModels()
            let result = try await manager.process(url)
            return result.segments.map {
                Span(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds))
            }
        } catch {
            return []
        }
    }

    /// A transcribed piece of speech with its time range.
    struct Piece: Sendable {
        let text: String
        let start: Double
        let end: Double
    }

    /// Joins transcript pieces into "Speaker 1: …" paragraphs. One speaker → plain paragraphs.
    static func label(_ pieces: [Piece], with spans: [Span]) -> String {
        guard !spans.isEmpty, Set(spans.map(\.speaker)).count > 1 else {
            return pieces.map(\.text).joined(separator: "\n\n")
        }
        var order: [String: Int] = [:]
        var lines: [(speaker: Int, text: String)] = []
        for piece in pieces {
            let best = spans.max { overlap($0, piece) < overlap($1, piece) }
            let id: String? = best.flatMap { overlap($0, piece) > 0 ? $0.speaker : nil }
            let number: Int
            if let id {
                if let known = order[id] {
                    number = known
                } else {
                    number = order.count + 1
                    order[id] = number
                }
            } else {
                number = lines.last?.speaker ?? 1
            }
            if let last = lines.last, last.speaker == number {
                lines[lines.count - 1].text += " " + piece.text
            } else {
                lines.append((number, piece.text))
            }
        }
        return lines.map { String(localized: "Speaker \($0.speaker)") + ": " + $0.text }
            .joined(separator: "\n\n")
    }

    private static func overlap(_ s: Span, _ p: Piece) -> Double {
        max(0, min(s.end, p.end) - max(s.start, p.start))
    }
}
