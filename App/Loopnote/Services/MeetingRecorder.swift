import AVFoundation
import Observation

/// Records a meeting to an AAC file. Keeps recording when the screen is locked
/// (background audio mode) and survives interruptions such as phone calls.
@MainActor
@Observable
final class MeetingRecorder {
    enum State { case idle, recording, paused }

    private(set) var state: State = .idle
    private(set) var elapsed: TimeInterval = 0
    /// 0…1 input level for the live waveform.
    private(set) var level: Float = 0
    private(set) var levels: [Float] = Array(repeating: 0, count: 48)
    var errorMessage: String?

    private var recorder: AVAudioRecorder?
    private var meterTask: Task<Void, Never>?
    private(set) var fileName: String?
    /// Closing the file after `stop()`; runs off the main thread.
    private var finalized: Task<Void, Never>?

    func start() async -> Bool {
        errorMessage = nil
        guard await AVAudioApplication.requestRecordPermission() else {
            errorMessage = String(localized: "Microphone access is turned off. You can allow it in Settings.")
            return false
        }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.defaultToSpeaker, .allowBluetoothHFP, .mixWithOthers])
            try session.setActive(true)
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
        let name = "meeting-\(Int(Date.now.timeIntervalSince1970)).m4a"
        let url = Meeting.directory.appendingPathComponent(name)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        do {
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.isMeteringEnabled = true
            guard r.record() else {
                errorMessage = String(localized: "Recording could not start.")
                return false
            }
            recorder = r
            fileName = name
            state = .recording
            startMetering()
            LiveActivityController.startMeeting(at: .now)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func pause() {
        recorder?.pause()
        state = .paused
        LiveActivityController.updateMeeting(start: .now.addingTimeInterval(-elapsed), paused: true)
    }

    func resume() {
        recorder?.record()
        state = .recording
        LiveActivityController.updateMeeting(start: .now.addingTimeInterval(-elapsed), paused: false)
    }

    /// Stops at once and returns the file name and duration. The UI never waits on the audio
    /// system: `AVAudioRecorder.stop()` (which writes the end of the file) and deactivating the
    /// audio session both run off the main thread. Await `finalized` before reading the file.
    func stop() -> (fileName: String, duration: TimeInterval)? {
        guard let recorder, let fileName else { return nil }
        let duration = max(recorder.currentTime, elapsed)
        meterTask?.cancel()
        meterTask = nil
        self.recorder = nil
        state = .idle
        LiveActivityController.endMeeting()
        nonisolated(unsafe) let r = recorder
        finalized = Task.detached(priority: .userInitiated) {
            r.stop()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        return (fileName, duration)
    }

    /// Finishes when the recording file is closed (or after `seconds`, whichever comes first),
    /// so processing never hangs on a stuck audio system.
    func waitUntilFinalized(seconds: Double = 5) async {
        guard let finalized else { return }
        _ = try? await withTimeout(seconds: seconds) { await finalized.value }
    }

    /// Stops and deletes the recording.
    func discard() {
        let name = fileName
        _ = stop()
        let pending = finalized
        if let name {
            Task.detached(priority: .utility) {
                await pending?.value
                try? FileManager.default.removeItem(at: Meeting.directory.appendingPathComponent(name))
            }
        }
        fileName = nil
        elapsed = 0
    }

    private func startMetering() {
        meterTask?.cancel()
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, let r = self.recorder else { return }
                r.updateMeters()
                let db = r.averagePower(forChannel: 0)            // -160…0
                let normalized = max(0, min(1, (db + 50) / 50))
                self.level = normalized
                if self.state == .recording {
                    self.elapsed = r.currentTime
                    self.levels.removeFirst()
                    self.levels.append(normalized)
                }
            }
        }
    }
}
