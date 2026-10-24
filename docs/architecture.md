# Speakty architecture

Speakty is a minimal native macOS dictation app. Hold a global shortcut, speak, release, and the transcript is pasted into the frontmost app. Transcription runs only on-device. It's a lean rebuild of the parts of Spokenly that Markus uses, in the design language of Shotty and Spotty.

This doc records the decisions made so far. Design and UX decisions live in the design artifacts (see References), not here.

## Goals

- Fast: text appears well under a second after releasing the shortcut for typical dictations.
- Accurate in German and English, including mixed technical vocabulary.
- Local only. No cloud models, API keys, accounts, sign-in, trials, or telemetry.
- Small surface. Every feature has to earn its place. Prefer YAGNI and add later.

## Stack

- Swift and SwiftUI, targeting macOS 26 or later on Apple Silicon, built with Xcode 27 like Shotty.
- SwiftUI for the app, settings window, and recording display. Drop to AppKit only where SwiftUI can't do the job: the non-activating floating `NSPanel` for the recording display, the shortcut recorder (an `NSButton` subclass, as in Shotty), the event tap, and `CGEvent` for paste. Follow Shotty's split and conventions where they apply.
- No Rust, Tauri, or Electron. The hard parts are Apple APIs: global hotkeys, `AVAudioEngine`, Accessibility, permissions, and Core ML on the Neural Engine.
- Distributed outside the App Store, Hardened Runtime, no App Sandbox, the same way as Shotty and Spokenly. Entitlement: audio input.
- Reuse Shotty's setup for signing, `Scripts/` (run, test, log, release, publish), Dev vs installed builds with separate bundle IDs, `AppPreferences` (typed sections persisted as JSON in UserDefaults), the Settings theme (`SettingsTheme`, `SettingsFormStyle`, sidebar rows, toolbar band), the `Chrome` and `Island` tokens for floating UI, `ShortcutRecorder`, and app updates (`Shotty/Updates`, Sparkle with gentle reminders and idle relaunch). Spotty is the reference for modifier-only shortcuts (`InputTap`, `TriggerEvent`).

## Transcription

- v1 ships one model: Parakeet Ultra, Moondream's post-trained Parakeet TDT 0.6B v3 (CC-BY-4.0, 25 European languages including German and English, automatic language detection).
- Runs through [FluidAudio](https://github.com/FluidInference/FluidAudio) on the Neural Engine. Core ML weights: `FluidInference/parakeet-ultra-coreml` (int8 encoder, about 630 MB on disk), loaded with `AsrModels.downloadAndLoad(version: .ultra)`. Tags v0.17.5 and later include Ultra; pin the newest tag (v0.17.7 at the time of writing).
- FluidAudio reports FLEURS WER of 11.67% for Ultra versus 14.81% for v3, at about the same speed (~127x realtime on the ANE).
- Batch transcription of the whole utterance after release. No streaming in v1.
- Load and warm the model at launch so the first dictation isn't slow. On first launch the download starts by itself, since dictation can't work without it. Downloads go to Application Support and show progress in Settings and the menu bar menu.
- Settings has a Models pane that lists local models and lets you pick one. It holds only Parakeet Ultra for now, but each model is a row with its own download, progress, remove, and selected state, so adding a model later is a new row, not a redesign. In code, keep one concrete `Transcriber` and extract a protocol when the second engine actually arrives.
- Later candidates, not in v1: Cohere Transcribe (2B, 14 languages, heavier, needs an explicit language and VAD) and Parakeet Redux (220 MB, slightly less accurate). Whisper is dropped.

## Accuracy features

- Vocabulary (names, product terms, jargon). Parakeet TDT has no decode-time biasing in FluidAudio. The supported path is TDT transcription plus a CTC rescoring pass: `VocabularyBoostingSession` runs Parakeet CTC 110M (an extra 97.5 MB download) over the same audio and swaps in a vocabulary term only when the acoustic evidence beats the original words. Download and load the CTC model only once the vocabulary has a word. Call `hasCTCRescoringCandidates` first, so dictations without a likely match skip the extra encoder pass. MacParakeet measured exact term recall going from 22% to 74% with `minSimilarity` 0.65, at +0.1 points of LibriSpeech WER; start there. The CTC model and its tokenizer are English, so German terms may boost less reliably. Terms have no aliases; a mishearing that boosting misses gets a replacement instead.
- Replacements, a deterministic step after vocabulary, run top to bottom. A plain rule matches whole words and ignores case. A regex rule uses `NSRegularExpression` with `$1` templates, for example `slash (\w+)\.?` to `/$1` and `dollar (\w+)\.?` to `\$$1`, the two rules Markus uses in Spokenly today. Invalid patterns are rejected in Settings.
- Trimming leading and trailing silence before inference, then padding about 0.5 s of real silence at the end. Without the pad the TDT decoder can drop a fast final word (MacParakeet issue 562).
- Keep recording for about 200 ms after release, so a word finished while letting go isn't clipped. A constant, not a setting.

No LLM rewriting and no cleanup model. Parakeet already writes punctuation and capitalization and mostly omits filler words.

## Flow

1. `HotkeyMonitor` sees the dictation shortcut go down. The default is Right ⌘, which is what Markus uses in Spokenly.
   - A modifier-only shortcut (a single modifier with its side, such as Right ⌘ or Right ⌥, Fn, or a chord such as ⌃⌥) comes from a session event tap watching `flagsChanged`, like Spotty's `InputTap`. The side comes from the key code (`kVK_RightCommand`). The tap needs Accessibility, which paste needs anyway, so Input Monitoring is never required. With Fn, Settings warns when macOS still uses 🌐 for something else (`AppleFnUsageType` in `com.apple.HIToolbox` isn't 0).
   - A key combination comes from `RegisterEventHotKey` with both `kEventHotKeyPressed` and `kEventHotKeyReleased`, which needs no permission.
   - Pressing any other key while a modifier-only shortcut is held means the user typed a shortcut such as ⌘C, so the dictation is discarded silently. A hold shorter than about 250 ms is also discarded.
   - While recording, Esc is registered as a temporary hotkey and cancels.
2. `AudioRecorder` starts capturing 16 kHz mono Float32 from a pre-warmed `AVAudioEngine` on the chosen input (system default or a specific device by UID, falling back to the default when that device is gone). Multi-channel inputs such as an audio interface are downmixed. The recording display appears immediately and switches from arming to live levels once the first buffer arrives. If "Mute audio while recording" is on, the default output is muted through Core Audio and restored on stop; a persisted flag restores it at the next launch if Speakty quit while muted.
3. On release, the recorder stops after the release tail, trims and pads silence, and hands the samples to `Transcriber`. Vocabulary rescoring and replacements run on the result.
4. `TextInserter` writes the text to the pasteboard, marked `org.nspasteboard.TransientType` so clipboard managers skip it, posts ⌘V with the key code that types "v" in the current layout (so Dvorak and Colemak work without a setting), and restores the previous clipboard contents shortly after. With "Match surrounding text" on, it first reads the text before the caret through Accessibility to add a leading space and lowercase the first letter mid-sentence; when an app doesn't expose it, the text goes in unchanged. Without Accessibility, the text stays on the clipboard and the display says so.
5. The last transcript stays in memory, so "Paste Last Transcript" in the menu bar menu (with an optional shortcut) recovers a dictation that landed in the wrong place.

## Structure

- One Xcode app target and a unit test target hosted in Speakty Dev, like Shotty and Spotty. A separate `Core` package isn't worth its setup yet: the engine pieces (`AudioRecorder`, `Transcriber`, `TextInserter`, `HotkeyMonitor`, transcript post-processing) live in `Speakty/Dictation` and `Speakty/Shortcuts`, and their pure logic is tested directly.
- Settings panes: General, Recording, Models, Transcript, Shortcuts, Permissions. First launch opens Permissions, as in Shotty.
- Permissions: Microphone, and Accessibility for paste, modifier-only shortcuts, and reading the text before the caret.

## Out of scope for v1

Cloud models, API keys, the OpenAI integration (ChatGPT dictation has no public API), sign-in, Pro and trial flows, dashboard or home, getting started, contact, history, file transcription, modes, AI rewriting and the cleanup model, settings sync, the MCP server, the CLI, smart paragraphs, pausing media, alternative paste methods, and trackpad or mouse button triggers.

Later, if the need shows up: tap-to-toggle with the same shortcut and quick send (Return while dictating sends), Parakeet Redux or Cohere as a second model, and retrying the last recording.

## References

- Design artifacts, published from `~/.codex/visualizations/2026/10/24/01a16dc6-c721-7232-bcd7-54afa2f4843e/`: `speakty-settings.html` (the Settings window) and `speakty-recording-display.html` (recording display styles and states, and the menu bar menu).
- Spokenly 2.31.2, installed at `/Applications/Spokenly.app`, for features and layout. It uses Sparkle, FluidAudio, whisper.cpp, and a media-remote adapter that likely pauses playback while dictating.
- Open-source apps with similar pipelines: MacParakeet (FluidAudio, custom vocabulary research in `docs/research/2026-07-04-custom-vocab-phase0.md`), VoiceInk (notch and mini recorders, word replacements, transient pasteboard type), Handy (overlay states such as arming until the first microphone sample).
- Shotty (`~/workspace/shotty`) and Spotty (`~/workspace/spotty`) for design language, settings layout, updates, scripts, and agent conventions.
