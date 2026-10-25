import AppKit
import AVFoundation
import Observation
import os

/// One dictation at a time: record while the shortcut is held, or from a tap of the shortcut, or
/// Start Dictation in the menu, until the next tap or Stop, then transcribe, post-process, and
/// paste. Escape cancels at any point.
@MainActor @Observable
final class DictationController {
    enum Phase: Equatable {
        case idle
        case recording(Trigger)
        case transcribing
    }

    /// How the shortcut ends a recording.
    enum Trigger: Equatable {
        /// Held since the key went down, in seconds since startup; the release ends it, unless that
        /// makes it a tap.
        case held(since: TimeInterval)
        /// Started by a tap or the menu; the next press of the shortcut ends it.
        case latched
        /// Pressed again to end it. The release ends it, and typing a shortcut such as ⌘C instead
        /// cancels it, as during a hold.
        case ending
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

    /// A release sooner than this after the press is a tap, which keeps recording until the next one.
    private static let longestTap: TimeInterval = 0.25
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
        switch Self.action(for: event, in: phase) {
        case .start(let trigger): start(trigger)
        case .become(let trigger): phase = .recording(trigger)
        case .stop: stop()
        case .cancel: cancel()
        case .ignore: break
        }
    }

    /// What a shortcut event does.
    enum Action: Equatable {
        case start(Trigger)
        /// Keeps recording, to be ended differently.
        case become(Trigger)
        case stop, cancel, ignore
    }

    /// The hold-or-tap rules: a hold records until its release, and a tap until the next tap. A tap
    /// is measured between the key's own event times, not when they're handled: starting a slow
    /// audio interface delays the release, which would otherwise turn every tap into a short hold.
    static func action(for event: HotkeyMonitor.Event, in phase: Phase) -> Action {
        switch (event, phase) {
        case (.pressed(let time), .idle): .start(.held(since: time))
        case (.pressed, .recording(.latched)): .become(.ending)
        case (.released(let time), .recording(.held(let since))): time - since < longestTap ? .become(.latched) : .stop
        case (.released, .recording(.ending)): .stop
        case (.interrupted, .recording(.held)), (.interrupted, .recording(.ending)): .cancel
        case (.escape, .recording), (.escape, .transcribing): .cancel
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
        do {
            try recorder.start(inputUID: preferences.recording.microphoneUID)
        } catch {
            NSSound.beep()
            return logger.error("Recording didn't start: \(error.localizedDescription, privacy: .public)")
        }
        phase = .recording(trigger)
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
        work = Task {
            // A cancel during the tail returns here, before it could stop a recording started since.
            do { try await Task.sleep(for: Self.releaseTail) } catch { return }
            let samples = recorder.stop()
            // Not before the tail ends, so resumed music doesn't end up in the recording.
            muter.restore()
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
                TextInserter.insert(text)
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
