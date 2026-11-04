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

    /// Stops and returns the file name and duration.
    func stop() -> (fileName: String, duration: TimeInterval)? {
        guard let recorder, let fileName else { return nil }
        let duration = recorder.currentTime
        recorder.stop()
        meterTask?.cancel()
        LiveActivityController.endMeeting()
        self.recorder = nil
        state = .idle
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return (fileName, max(duration, elapsed))
    }

    /// Stops and deletes the recording.
    func discard() {
        let name = fileName
        _ = stop()
        if let name { try? FileManager.default.removeItem(at: Meeting.directory.appendingPathComponent(name)) }
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
