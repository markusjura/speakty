# Speakty architecture

Speakty is a minimal dictation app for macOS and Linux. Hold a global shortcut, speak, release, and the transcript is pasted into the frontmost app. Transcription runs only on-device. It's a lean rebuild of the parts of Spokenly that Markus uses, in the design language of Shotty and Spotty.

This is a high-level overview. The code is the source of truth for details.

## Principles

- Local only. No cloud models, accounts, or telemetry.
- Fast. Text appears well under a second after release for typical dictations.
- Accurate in German and English, including technical vocabulary.
- Small surface. Every feature earns its place; extract abstractions only when a second case arrives.
- Native. Swift and SwiftUI on macOS 26 and Apple Silicon, AppKit only where SwiftUI can't do the job. Rust and GTK 4 on Linux.

## Components on macOS

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

## Permissions on macOS

- Microphone, for recording.
- Accessibility, for paste, modifier-key shortcuts, and reading the text before the caret. Input Monitoring is never needed.
- Without Accessibility, key-combination shortcuts and the menu still dictate, and the transcript stays on the clipboard.

## Builds on macOS

- One app target and a unit test target hosted in Speakty Dev.
- Speakty Dev and the installed Speakty have separate bundle IDs and share the downloaded models. They share the shortcut too, so launching one quits the other.
- Distributed outside the App Store with Hardened Runtime, no App Sandbox, and Sparkle updates.
- Signing, `macos/Scripts/`, `AppPreferences`, the Settings theme, `Chrome` tokens, `ShortcutRecorder`, and `AppUpdater` follow Shotty and Spotty.

## Linux

The Linux app in `linux/` ports the same pipeline, decisions, and settings to Rust and GTK 4 with libadwaita. It shares no code with the macOS app, since the only portable part, the transcript rules, is a few hundred lines. `spec/transcript-cases.json` keeps the two rule sets in step: both test suites run every case in it.

- `HotkeyMonitor` reads every keyboard in `/dev/input` with evdev. It works under any Wayland compositor, sees a modifier key such as Right Super held alone, and sees the keys typed during a hold. Remappers such as kanata grab the physical keyboard and type through a virtual one, which it reads like any other. It needs the `input` group, and no app can take a key away from the app in front on Wayland, so Cancel's Esc reaches that app too, and there's no Send shortcut.
- `Recorder` records a fresh PipeWire stream per dictation on a PipeWire thread of its own. It asks for as many channels as the source has, linked one to one, since PipeWire would otherwise mix an interface's channels to stereo; then it picks the voice as the macOS app does: channel 1 of an interface, both of a stereo microphone.
- `Transcriber` runs Parakeet Ultra, converted to sherpa-onnx's format and quantized to int8, on the CPU. A Ryzen 7 5700X3D transcribes 5 s of speech in 0.2 s and 24 s in 0.8 s. The vocabulary goes in as hotwords for beam search, which replaces the macOS app's CTC rescoring pass. The GPU stays unused: ONNX Runtime dropped ROCm, and the CPU is fast enough.
- `Paster` pastes through the clipboard with the Wayland data-control protocol, then presses Ctrl+V, or Ctrl+Shift+V in a terminal, on a uinput virtual keyboard, then restores the clipboard. Each copy carries KDE's password manager hint, which clipboard histories such as cliphist and Klipper skip. Hyprland and Sway name the app in front; elsewhere it's Ctrl+V. Without write access to `/dev/uinput`, the transcript stays on the clipboard.
- `Overlay` draws the recording display on a gtk4-layer-shell surface that takes no focus and no clicks. The Glass style needs Liquid Glass, so Linux has Dark and Orb.
- Smart spacing needs the text before the caret, which Linux apps don't expose reliably, so it's off on Linux.
- Media pauses through MPRIS, and the output mutes through WirePlumber's `wpctl`.
- The tray icon is optional and off by default; Settings opens from the app launcher. A second launch hands its command to the running Speakty through GApplication, so `speakty settings`, `speakty toggle`, and `speakty status` reach it.
- Speakty installs per user, without root: each version in `~/.local/share/speakty/versions`, with `current` and `previous` links, and the `speakty.service` user unit. The updater follows the macOS app's rules. It reads `speakty-linux.json` from the latest GitHub release, which carries both apps under one version, verifies the archive with Sparkle's EdDSA key, switches `current` atomically, and replaces its process once no dictation runs and the keyboards rested for ten minutes.

## Design

Design decisions live in the design artifacts in `~/.codex/visualizations/2026/10/24/01a16dc6-c721-7232-bcd7-54afa2f4843e/`: `speakty-settings.html`, `speakty-recording-display.html`, and `speakty-menu-bar.html`.
