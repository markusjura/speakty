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
- Reuse Shotty's setup for signing, `Scripts/` (run, test, log, release, publish), Dev vs installed builds with separate bundle IDs, `AppPreferences` (typed sections persisted as JSON in UserDefaults), the Settings theme (`SettingsTheme`, `SettingsFormStyle`, sidebar rows, toolbar band), the `Chrome` tokens for floating UI, `ShortcutRecorder`, and app updates (`Shotty/Updates`, Sparkle with gentle reminders and idle relaunch). Spotty is the reference for watching a modifier key with an event tap.

## Transcription

- v1 ships one model: Parakeet Ultra, Moondream's post-trained Parakeet TDT 0.6B v3 (CC-BY-4.0, 25 European languages including German and English, automatic language detection).
- Runs through [FluidAudio](https://github.com/FluidInference/FluidAudio) on the Neural Engine. Core ML weights: `FluidInference/parakeet-ultra-coreml` (int8 encoder, about 630 MB on disk), loaded with `AsrModels.downloadAndLoad(version: .ultra)`. Tags v0.17.5 and later include Ultra; pin the newest tag (v0.17.7 at the time of writing).
- FluidAudio reports FLEURS WER of 11.67% for Ultra versus 14.81% for v3, at about the same speed (~127x realtime on the ANE).
- Batch transcription of the whole utterance after release. No streaming in v1.
- Load and warm the model at launch so the first dictation isn't slow. On first launch the download starts by itself, since dictation can't work without it. Downloads go to `~/Library/Application Support/FluidAudio`, shared by Speakty and Speakty Dev, and show progress in Settings > Models. Until the model is ready, the shortcut beeps and Start Dictation is disabled.
- Settings has a Models pane that lists local models. It holds only Parakeet Ultra, which is selected whenever it's downloaded, but each model is a row with its own download, progress, remove, and selected state, so adding a model later is a new row, not a redesign. In code, keep one concrete `Transcriber` and extract a protocol when the second engine actually arrives.
- Later candidates, not in v1: Cohere Transcribe (2B, 14 languages, heavier, needs an explicit language and VAD) and Parakeet Redux (220 MB, slightly less accurate). Whisper is dropped.

## Accuracy features

- Vocabulary (names, product terms, jargon). Parakeet TDT has no decode-time biasing in FluidAudio. The supported path is TDT transcription plus a CTC rescoring pass: `VocabularyBoostingSession` runs Parakeet CTC 110M (an extra 97.5 MB download) over the same audio and swaps in a vocabulary term only when the acoustic evidence beats the original words. Speakty downloads and loads the CTC model only once the vocabulary has a word, keeps it loaded, and rebuilds only the session when the vocabulary changes. When building it fails, as without network for the first download, the next dictation tries again. FluidAudio's rescored text drops the punctuation after a replaced phrase ("Shoddy, Spotty" became "Shotty Spotty"), so Speakty applies its replacements to the original text itself. MacParakeet measured exact term recall going from 22% to 74% with `minSimilarity` 0.65, at +0.1 points of LibriSpeech WER, so Speakty uses that. It also turns off FluidAudio's acoustic spotter rescue, which FluidAudio recommends for short names that sound like ordinary words; with it on, "pastes the text" became "Spotty" in testing. Rescoring a dictation takes a fraction of a second. FluidAudio 0.17.7 has no `hasCTCRescoringCandidates` preflight yet; adopt it when upgrading. The CTC model and its tokenizer are English, so German terms may boost less reliably. Terms have no aliases; a mishearing that boosting misses gets a replacement instead.
- Replacements, a deterministic step after vocabulary, run top to bottom. A plain rule matches whole words and ignores case. A regex rule uses `NSRegularExpression` with `$1` templates, for example `slash (\w+)\.?` to `/$1` and `dollar (\w+)\.?` to `\$$1`, the two rules Markus uses in Spokenly today. Invalid patterns are rejected in Settings.
- Trimming leading and trailing silence before inference, then padding about 0.5 s of real silence at the end. Without the pad the TDT decoder can drop a fast final word (MacParakeet issue 562).
- Keep recording for about 200 ms after release, so a word finished while letting go isn't clipped. A constant, not a setting.

No LLM rewriting and no cleanup model. Parakeet already writes punctuation and capitalization and mostly omits filler words.

## Flow

1. `HotkeyMonitor` sees the dictation shortcut go down. The default is Right ⌘, which is what Markus uses in Spokenly.
   - A modifier shortcut (a single modifier key with its side, such as Right ⌘ or Right ⌥, or Fn) comes from a session event tap watching `flagsChanged`, like Spotty's `InputTap`. The device-dependent flag bits tell left from right. Chords such as ⌃⌥ aren't supported; nobody needs them yet. The tap needs Accessibility, which paste needs anyway, so Input Monitoring is never required. With Fn, Settings warns when macOS still uses 🌐 for something else (`AppleFnUsageType` in `com.apple.HIToolbox` isn't 0).
   - A key combination comes from `RegisterEventHotKey` with both `kEventHotKeyPressed` and `kEventHotKeyReleased`, which needs no permission.
   - Pressing any other key while a modifier-only shortcut is held means the user typed a shortcut such as ⌘C, so the dictation is discarded silently.
   - A tap, released within 250 ms, starts a dictation that runs until the next tap, as Spokenly's "Hold or Toggle" does. That tap ends it on release, so a ⌘C typed with it still discards.
   - While recording, Esc is registered as a temporary hotkey and cancels, also with a held key shortcut's modifiers.
   - Start Dictation in the menu bar menu records until Stop Dictation or the shortcut, for when a hand is on the mouse.
2. `AudioRecorder` starts capturing 16 kHz mono Float32 from a fresh `AVAudioEngine` on the chosen input (system default or a specific device by UID, falling back to the default when that device is gone). A fresh engine keeps the microphone and its indicator off between dictations. The engine lives on a serial queue of its own, as `AVCaptureSession` does in Apple's samples: starting the Vocaster takes about 600 ms, which on the main thread held up the shortcut's key events and turned every tap into a short hold. Mono and stereo inputs are mixed to mono. Interfaces with more channels record channel 1 alone: the Vocaster puts its video call mix there, and a mix of all ten channels comes out silent. A chosen device is set on the input unit while it's uninitialized; set on the initialized unit, the engine delivers no audio. The tap then keeps the default device's channel count with the chosen device's channels first, so the device's own format decides how many channels to mix. The recording display appears at once, and the start sound plays once the microphone is live. If "Mute audio while recording" is on, the default output is muted through Core Audio after the start sound and restored once the release tail ends, on cancel, and on quit; the muted device's UID is kept in defaults until it unmutes, so the launch after a crash, or the next stop after a failed unmute, unmutes it.
3. On release, the recorder stops after the release tail, trims and pads silence, and hands the samples to `Transcriber`. Vocabulary rescoring and replacements run on the result.
4. `TextInserter` writes the text to the pasteboard, marked `org.nspasteboard.TransientType` so clipboard managers skip it, posts ⌘V with the key code that types "v" with ⌘ held in the current layout (so Dvorak, Colemak, and "Dvorak - QWERTY ⌘" work without a setting), and restores the previous clipboard contents shortly after. With "Smart spacing and capitalization" on, it first reads the text before the caret through Accessibility to add a leading space and lowercase the first letter mid-sentence, unless it's "I", an acronym, or starts a vocabulary name; when an app doesn't expose it, the text goes in unchanged. Without Accessibility, the text stays on the clipboard.

## Recording display and menu bar

- The display shows two states only: listening, which follows the voice level, and transcribing, which keeps moving without it. No record dot, and no pasted, no-speech, download, or error states; a beep covers the rare failure, and Settings shows model downloads.
- Three styles, chosen in Settings > Recording with live previews: Minimal (level bars in Shotty's dark capsule, the default), Glass (a scrolling waveform in a Liquid Glass capsule), and Orb (a gradient ring that breathes with the voice and turns while transcribing). Position is bottom or top of the screen with the pointer.
- It's a borderless, non-activating, click-through `NSPanel` on every Space, so focus stays in the app being typed in. Its animation clock stops while it's hidden.
- The menu bar icon is the `waveform` symbol and never changes with the dictation state; a blue dot marks an update that needs the user. The menu holds Start or Stop Dictation, Settings, and Quit.

## Structure

- One Xcode app target and a unit test target hosted in Speakty Dev, like Shotty and Spotty. A separate `Core` package isn't worth its setup yet: the engine pieces (`AudioRecorder`, `Transcriber`, `TextInserter`, `HotkeyMonitor`, transcript post-processing) live in `Speakty/Dictation` and `Speakty/Shortcuts`, and their pure logic is tested directly.
- Settings panes: General, Recording, Models, Transcript, Shortcuts, Permissions. First launch opens Permissions, as in Shotty.
- Permissions: Microphone, and Accessibility for paste, modifier-only shortcuts, and reading the text before the caret.

## Out of scope for v1

Cloud models, API keys, the OpenAI integration (ChatGPT dictation has no public API), sign-in, Pro and trial flows, dashboard or home, getting started, contact, history and Paste Last Transcript, file transcription, modes, AI rewriting and the cleanup model, settings sync, the MCP server, the CLI, smart paragraphs, pausing media, alternative paste methods, and trackpad or mouse button triggers.

Later, if the need shows up: quick send (Return while dictating sends), Parakeet Redux or Cohere as a second model, and retrying the last recording.

## References

- Design artifacts, published from `~/.codex/visualizations/2026/10/24/01a16dc6-c721-7232-bcd7-54afa2f4843e/`: `speakty-settings.html` (the Settings window), `speakty-recording-display.html` (the three display styles and their two states), and `speakty-menu-bar.html` (menu bar icon options and the menu).
- Spokenly 2.31.2, installed at `/Applications/Spokenly.app`, for features and layout. It uses Sparkle, FluidAudio, whisper.cpp, and a media-remote adapter that likely pauses playback while dictating.
- Open-source apps with similar pipelines: MacParakeet (FluidAudio, custom vocabulary research in `docs/research/2026-07-04-custom-vocab-phase0.md`), VoiceInk (notch and mini recorders, word replacements, transient pasteboard type), Handy (overlay states such as arming until the first microphone sample).
- Shotty (`~/workspace/shotty`) and Spotty (`~/workspace/spotty`) for design language, settings layout, updates, scripts, and agent conventions.
