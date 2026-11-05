import AVFoundation
import Foundation

/// Renders an utterance to PCM buffers and returns when speech is complete.
///
/// `AVSpeechSynthesizer.write` used to end with an empty buffer; on newer systems that last
/// buffer does not always arrive. Completion is therefore detected by whichever comes first:
/// the empty buffer, a short silence after the last buffer, or a hard time limit.
enum SpeechWriter {
    static let idleGap: TimeInterval = 1.2
    static let limit: TimeInterval = 25

    /// Calls `onBuffer` for every non-empty buffer (on the synthesizer's queue).
    /// Throws only when no audio at all was produced.
    nonisolated static func write(_ utterance: AVSpeechUtterance,
                                  onBuffer: @escaping @Sendable (AVAudioPCMBuffer) throws -> Void) async throws {
        let synthesizer = AVSpeechSynthesizer()
        let state = State()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            state.continuation = cont
            let started = Date()
            Task.detached {
                while !state.isFinished {
                    try? await Task.sleep(for: .milliseconds(300))
                    let now = Date()
                    if let last = state.lastBuffer, now.timeIntervalSince(last) > idleGap {
                        state.finish(nil)
                    } else if now.timeIntervalSince(started) > limit {
                        state.finish(state.lastBuffer == nil ? CancellationError() : nil)
                    }
                }
            }
            synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    state.finish(nil)
                    return
                }
                do {
                    if state.accept() { try onBuffer(pcm) }
                } catch {
                    state.finish(error)
                }
            }
        }
        withExtendedLifetime(synthesizer) {}
    }

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        var continuation: CheckedContinuation<Void, Error>?
        private var done = false
        private var last: Date?

        var lastBuffer: Date? { lock.lock(); defer { lock.unlock() }; return last }
        var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return done }

        /// Records a buffer; false once finished (late buffers are dropped).
        func accept() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !done else { return false }
            last = Date()
            return true
        }

        func finish(_ error: Error?) {
            lock.lock()
            guard !done, let cont = continuation else { lock.unlock(); return }
            done = true
            continuation = nil
            lock.unlock()
            if let error { cont.resume(throwing: error) } else { cont.resume() }
        }
    }
}
