import AppKit
import AVFoundation
import Observation
import os

/// One dictation at a time: record while the shortcut is held, or between Start and Stop in the
/// menu, then transcribe, post-process, and paste. Escape cancels at any point.
@MainActor @Observable
final class DictationController {
    enum Phase: Equatable {
        case idle
        /// `isHeld` is true when the shortcut started it and its release ends it; the menu starts
        /// recordings that run until Stop or the shortcut.
        case recording(since: ContinuousClock.Instant, isHeld: Bool)
        case transcribing
    }

    private(set) var phase = Phase.idle

    let recorder = AudioRecorder()
    @ObservationIgnored private let preferences: AppPreferences
    @ObservationIgnored private let permissions: Permissions
    @ObservationIgnored private let transcriber: Transcriber
    @ObservationIgnored private let muter = OutputMuter()
    @ObservationIgnored private let openPermissions: @MainActor () -> Void
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private let logger = Logger(subsystem: "local.markus.Speakty", category: "Dictation")

    /// A hold shorter than this is a slip, such as tapping Right ⌘ on the way to another key.
    private static let shortestHold = Duration.milliseconds(250)
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
        switch (event, phase) {
        case (.pressed, .idle): start(isHeld: true)
        case (.pressed, .recording): stop()
        case (.released, .recording(let since, true)):
            if since.duration(to: .now) < Self.shortestHold { cancel() } else { stop() }
        case (.interrupted, .recording(_, true)), (.escape, _): cancel()
        default: break
        }
    }

    /// Starts a recording that runs until `stop()`, as the menu's Start Dictation does.
    func toggle() {
        if isRecording { stop() } else if phase == .idle { start(isHeld: false) }
    }

    private func start(isHeld: Bool) {
        guard transcriber.state == .ready else {
            NSSound.beep()
            return logger.info("Dictation waits for the model: \(String(describing: self.transcriber.state), privacy: .public)")
        }
        switch recorder.usesMicrophone ? permissions.microphone : .authorized {
        case .authorized: break
        case .notDetermined:
            // macOS asks once; the next press records.
            Task { _ = await permissions.requestMicrophone() }
            return
        default:
            return openPermissions()
        }
        do {
            try recorder.start(inputUID: preferences.recording.microphoneUID)
        } catch {
            NSSound.beep()
            return logger.error("Recording didn't start: \(error.localizedDescription, privacy: .public)")
        }
        phase = .recording(since: .now, isHeld: isHeld)
        play(.start)
        if preferences.recording.mutesAudio {
            // After the start sound, which muting would cut off.
            work = Task {
                try? await Task.sleep(for: .milliseconds(150))
                if isRecording { muter.mute() }
            }
        }
    }

    private func stop() {
        guard isRecording else { return }
        phase = .transcribing
        work?.cancel()
        muter.restore()
        work = Task {
            // A cancel during the tail returns here, before it could stop a recording started since.
            do { try await Task.sleep(for: Self.releaseTail) } catch { return }
            let speech = Transcript.speech(in: recorder.stop())
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
                await TextInserter.insert(text)
                play(.done)
            } catch {
                NSSound.beep()
                logger.error("Transcription failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Also runs on quit, so a recording never leaves the output muted.
    func cancel() {
        guard phase != .idle else { return }
        work?.cancel()
        work = nil
        recorder.cancel()
        muter.restore()
        phase = .idle
        logger.info("Cancelled")
    }

    private enum Sound: String {
        case start = "Tink", done = "Pop"
    }

    private func play(_ sound: Sound) {
        guard preferences.general.playsSounds, let player = NSSound(named: sound.rawValue) else { return }
        player.volume = 0.35
        player.play()
    }
}
