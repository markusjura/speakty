# Project instructions

This file documents guidance for agents working in this repository. Record only non-obvious pitfalls, surprises, and constraints of the workflow and tools, and add new ones when you discover them. Explain code pitfalls in a comment where they apply, not here.

Speakty is Shotty's and Spotty's sibling. Keep shared patterns (Settings layout and theme, `ShortcutRecorder`, `AppPreferences`, `AppUpdater`, `Chrome` tokens, scripts) consistent with `~/workspace/shotty` and `~/workspace/spotty` unless Speakty needs something different. `docs/architecture.md` records the architecture decisions.

## Commands

- `Scripts/run.sh dev` builds and relaunches Speakty Dev. Run it after every successful change, so the running app matches the code.
- `Scripts/run.sh installed` switches back to the installed Speakty.
- `Scripts/test.sh [TestClass]` runs all unit tests or one class.
- `Scripts/log.sh` streams Speakty's log: recordings, transcriptions, cancels, and errors.
- Run `Scripts/release.sh` and `Scripts/publish.sh` only when I ask.
- In a new worktree, run `./.worktree-setup.sh` once if the build fails with "Signing for Speakty requires a development team". It links `Local.xcconfig` from the main checkout, and not every worktree tool runs it.

## Verifying UI changes

`Scripts/ui/speakty-ui` drives the app and reports the result as text. It targets Speakty Dev when it runs, else the installed Speakty. Run it without arguments for usage. It compiles itself into `.build` on first use.

- Prefer checks that print text over screenshots. `windows` lists the overlay panel and Settings with their frames, `menu` lists or chooses menu bar items, `pad` prints what a dictation pastes, and `clipboard` prints the clipboard.
- `hold rcmd 2` holds Right ⌘ for two seconds at the HID level, where the dictation shortcut sees it. Computer Use can't hold a key, so use this for every hold-to-talk check.
- To dictate without speaking, point Speakty Dev at a recording: `say -o /tmp/speech.wav --data-format=LEF32@16000 "…"`, then `defaults write local.markus.Speakty.dev testAudioFile /tmp/speech.wav`. It replays the file in real time instead of the microphone, and skips the microphone permission. `defaults delete local.markus.Speakty.dev testAudioFile` switches back.
- Check pasted text with `pad`, never in the Codex composer, TextEdit, or Notes. It opens a text window in front and prints what lands in it: `Scripts/ui/speakty-ui pad 30 & sleep 1.5; Scripts/ui/speakty-ui hold rcmd 8; wait`. Hold at least as long as the recording. Speakty Dev restores the clipboard after pasting, so `clipboard` won't show the transcript.
- Pasting and the Right ⌘ shortcut need Speakty Dev to have Accessibility, which only I can grant. Without it, `menu "Start Dictation"` and `menu "Stop Dictation"` still dictate, and the transcript stays on the clipboard.
- Take screenshots with `screencapture -x -R x,y,w,h`, using a frame from `windows`. Screenshots are in pixels, twice the points on this Mac's displays. Shrink large ones with `sips -Z 900` before viewing.
- Use Computer Use for exploratory checks and for judging how something looks. In Computer Use, get Speakty Dev by the full path of `~/Applications/Speakty Dev.app`, with `~` expanded.
- Don't mix Computer Use and posted input in one check. While Computer Use is attached, its shield takes the events `speakty-ui` posts.

### Clean up

Afterwards, clear the clipboard and delete `testAudioFile`. If the task was only your own verification, run `Scripts/run.sh installed`; otherwise leave Speakty Dev running for me.
