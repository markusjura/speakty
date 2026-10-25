import AppKit
import AVFoundation
import Observation
import os

/// One dictation at a time: record while the shortcut is held, or from a tap of the shortcut, or
/// Start Dictation in the menu, until the next press or Stop, then transcribe, post-process, and
/// paste. Cancel discards it at any point, and Send presses Return after the paste.
@MainActor @Observable
final class DictationController {
    enum Phase: Equatable {
        case idle
        case recording(Trigger)
        case transcribing
    }

    /// How the shortcut ends a recording.
    enum Trigger: Equatable {
        /// Down since this instant. The release ends the recording or, as a tap, latches it.
        case held(since: ContinuousClock.Instant)
        /// Runs until the next press of the shortcut, or Stop Dictation in the menu.
        case latched
    }

    private(set) var phase = Phase.idle

    let recorder = AudioRecorder()
    @ObservationIgnored private let preferences: AppPreferences
    @ObservationIgnored private let permissions: Permissions
    @ObservationIgnored private let transcriber: Transcriber
    @ObservationIgnored private let muter = OutputMuter()
    @ObservationIgnored private let media = MediaPauser()
    @ObservationIgnored private let openPermissions: @MainActor () -> Void
    @ObservationIgnored private var work: Task<Void, Never>?
    /// Counts recordings, so a microphone that starts late can tell whether its recording still runs.
    @ObservationIgnored private var recordings = 0
    /// Set by Send, which presses Return once the text is pasted.
    @ObservationIgnored private var sends = false
    @ObservationIgnored private let logger = Logger(subsystem: "local.markus.Speakty", category: "Dictation")

    /// In Hold or tap, a release sooner than this after the press is a tap.
    private static let longestTap = Duration.milliseconds(250)
    /// Recording continues briefly after release, so a word finished while letting go isn't cut.
    private static let releaseTail = Duration.milliseconds(200)

    init(preferences: AppPreferences, permissions: Permissions, transcriber: Transcriber,
         openPermissions: @escaping @MainActor () -> Void) {
        self.preferences = preferences
        self.permissions = permissions
        self.transcriber = transcriber
        self.openPermissions = openPermissions
    }

    var isRecording: Bool {
        if case .recording = phase { true } else { false }
    }

    /// Whether Start Dictation can run now.
    var canStart: Bool { phase == .idle && transcriber.state == .ready }

    func handle(_ event: HotkeyMonitor.Event) {
        switch Self.action(for: event, in: phase, mode: preferences.recording.shortcutMode, at: .now) {
        case .start(let trigger): start(trigger)
        case .latch: phase = .recording(.latched)
        case .stop: stop()
        case .send:
            sends = true
            stop()
        case .cancel: cancel()
        case .ignore: break
        }
    }

    /// What a shortcut event does.
    enum Action: Equatable {
        case start(Trigger)
        /// Keeps recording until the next press.
        case latch
        case stop, send, cancel, ignore
    }

    /// Every press starts as a hold, and the mode decides what its release does. Another key typed
    /// with a held modifier shortcut, as in Right ⌘C, means the press was a shortcut, not dictation.
    static func action(for event: HotkeyMonitor.Event, in phase: Phase, mode: ShortcutMode,
                       at now: ContinuousClock.Instant) -> Action {
        switch (event, phase) {
        case (.pressed, .idle): .start(.held(since: now))
        case (.released, .recording(.held(let since))):
            switch mode {
            case .hold: .stop
            case .tap: .latch
            case .holdOrTap: since.duration(to: now) < longestTap ? .latch : .stop
            }
        case (.pressed, .recording(.latched)): .stop
        case (.interrupted, .recording(.held)): .cancel
        case (.cancel, .recording), (.cancel, .transcribing): .cancel
        case (.send, .recording), (.send, .transcribing): .send
        default: .ignore
        }
    }

    /// Starts a recording that runs until `stop()`, as the menu's Start Dictation does.
    func toggle() {
        if isRecording { stop() } else if phase == .idle { start(.latched) }
    }

    private func start(_ trigger: Trigger) {
        guard transcriber.state == .ready else {
            NSSound.beep()
            return logger.info("Dictation waits for the model: \(String(describing: self.transcriber.state), privacy: .public)")
        }
        // Speakty is rarely active, when access is re-read, so a revoked microphone would record silence.
        permissions.refresh()
        switch recorder.usesMicrophone ? permissions.microphone : .authorized {
        case .authorized: break
        case .notDetermined:
            // macOS asks once; the next press records.
            Task { _ = await permissions.requestMicrophone() }
            return
        default:
            return openPermissions()
        }
        recordings += 1
        let recording = recordings
        recorder.start(inputUID: preferences.recording.microphoneUID) { [weak self] result in
            guard let self, recording == recordings else { return }
            microphoneStarted(result)
        }
        phase = .recording(trigger)
        sends = false
    }

    /// The display shows at once; the start sound waits for the microphone, which can take half a
    /// second, so it tells when speech is heard.
    private func microphoneStarted(_ result: Result<Void, any Error>) {
        switch result {
        case .success:
            guard isRecording else { return }
            play(.start)
            if preferences.recording.pausesMedia { media.pause() }
            if preferences.recording.mutesAudio {
                // After the start sound, which muting would cut off.
                work = Task {
                    try? await Task.sleep(for: .milliseconds(150))
                    if isRecording { muter.mute() }
                }
            }
        case .failure(let error):
            // Unless Cancel ended the recording meanwhile.
            guard isRecording else { return }
            NSSound.beep()
            logger.error("Recording didn't start: \(error.localizedDescription, privacy: .public)")
            cancel()
        }
    }

    private func stop() {
        guard isRecording else { return }
        phase = .transcribing
        work?.cancel()
        work = Task {
            // A cancel during the tail returns here, before it could stop a recording started since.
            do { try await Task.sleep(for: Self.releaseTail) } catch { return }
            let samples = await recorder.stop()
            // A cancel meanwhile has already restored the output, and a new recording may run.
            guard !Task.isCancelled else { return }
            // Not before the tail ends, so resumed music doesn't end up in the recording.
            muter.restore()
            media.resume()
            let speech = Transcript.speech(in: samples)
            defer { if !Task.isCancelled { phase = .idle } }
            guard !speech.isEmpty else { return logger.info("Heard no speech") }
            do {
                let transcript = preferences.transcript
                let raw = try await transcriber.transcribe(speech)
                guard !Task.isCancelled else { return }
                var text = Transcript.applying(transcript.replacements, to: raw).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                if transcript.matchesSurroundingText {
                    text = Transcript.fitting(text, after: TextInserter.textBeforeCaret(), keepingCaseOf: transcript.vocabulary)
                }
                TextInserter.insert(text, pressingReturn: sends)
                play(.done)
            } catch {
                NSSound.beep()
                logger.error("Transcription failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Also runs on quit, so a recording never leaves the output muted or media paused.
    func cancel() {
        guard phase != .idle else { return }
        work?.cancel()
        work = nil
        recorder.cancel()
        muter.restore()
        media.resume()
        phase = .idle
        logger.info("Cancelled")
    }

    private enum Sound: String {
        case start = "Tink", done = "Pop"
    }

    private func play(_ sound: Sound) {
        guard preferences.recording.playsSounds, let player = NSSound(named: sound.rawValue) else { return }
        player.volume = 0.35
        player.play()
    }
}
