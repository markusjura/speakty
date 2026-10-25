# Speakty architecture

Speakty is a minimal native macOS dictation app. Hold a global shortcut, speak, release, and the transcript is pasted into the frontmost app. Transcription runs only on-device. It's a lean rebuild of the parts of Spokenly that Markus uses, in the design language of Shotty and Spotty.

This is a high-level overview. The code is the source of truth for details.

## Principles

- Local only. No cloud models, accounts, or telemetry.
- Fast. Text appears well under a second after release for typical dictations.
- Accurate in German and English, including technical vocabulary.
- Small surface. Every feature earns its place; extract abstractions only when a second case arrives.
- Native. Swift and SwiftUI on macOS 26 and Apple Silicon, AppKit only where SwiftUI can't do the job.

## Components

`SpeaktyApplicationDelegate` creates the long-lived objects at launch and wires them together with Observation.

- `HotkeyMonitor` turns the dictation shortcut and Esc into events. A modifier key such as Right ⌘ comes from an event tap; a key combination comes from `RegisterEventHotKey`.
- `DictationController` owns the dictation state (idle, recording, transcribing) and runs the pipeline. It's the only place that coordinates the other pieces.
- `AudioRecorder` records 16 kHz mono from a fresh `AVAudioEngine` per dictation.
- `Transcriber` downloads, loads, and runs Parakeet Ultra through FluidAudio on the Neural Engine, and rescores against the vocabulary with a small CTC model when there is one.
- `Transcript` holds the pure steps between audio and paste: silence trimming, replacements, vocabulary corrections, smart paragraphs, and fitting text to what's before the caret.
- `TextInserter` pastes through the clipboard with ⌘V, then restores the previous clipboard.
- `OverlayController` shows the recording display in a non-activating, click-through panel, so focus stays in the app being typed in.
- `AppPreferences` is the one typed preference store, `Permissions` tracks Microphone and Accessibility, and `AppUpdater` runs Sparkle.

## Dictation pipeline

1. The shortcut is held to talk, or tapped to toggle. Typing another key during a hold, or Esc, cancels.
2. Recording continues for a short tail after release.
3. Silence is trimmed and padded, then the samples are transcribed in one batch. No streaming.
4. Replacements run, and an open last sentence of a multi-sentence transcript gets a period. With smart paragraphs on, a spoken "new paragraph" becomes a blank line and a long transcript is split into paragraphs, and with smart spacing on, the text is fitted to what's before the caret.
5. The text is pasted. Failures beep and log; there is no error UI.

## Decisions

- One model, Parakeet Ultra, with automatic language detection. Models are rows in Settings > Models, but the code keeps one concrete `Transcriber` until a second engine arrives.
- No LLM rewriting or cleanup model. Parakeet already writes punctuation and capitalization.
- Smart paragraphs choose breaks at sentence boundaries by cost: even paragraph lengths, and openings that change or continue the topic. Pauses aren't used, since a pause to think is as long as a pause between topics. A spoken "new paragraph" breaks exactly where it's said. No model, so it's instant and predictable.
- App state lives on the main actor. The audio engine lives on the recorder's own serial queue, so starting a slow interface never delays shortcut events.
- Decision logic lives in pure functions, such as the hold-or-tap rules and `Transcript`, and is unit tested directly.
- Updates relaunch the app only when no dictation is running.

## Permissions

- Microphone, for recording.
- Accessibility, for paste, modifier-key shortcuts, and reading the text before the caret. Input Monitoring is never needed.
- Without Accessibility, key-combination shortcuts and the menu still dictate, and the transcript stays on the clipboard.

## Builds

- One app target and a unit test target hosted in Speakty Dev.
- Speakty Dev and the installed Speakty have separate bundle IDs and share the downloaded models. They share the shortcut too, so launching one quits the other.
- Distributed outside the App Store with Hardened Runtime, no App Sandbox, and Sparkle updates.
- Signing, `macos/Scripts/`, `AppPreferences`, the Settings theme, `Chrome` tokens, `ShortcutRecorder`, and `AppUpdater` follow Shotty and Spotty.

## Design

Design decisions live in the design artifacts in `~/.codex/visualizations/2026/10/24/01a16dc6-c721-7232-bcd7-54afa2f4843e/`: `speakty-settings.html`, `speakty-recording-display.html`, and `speakty-menu-bar.html`.
