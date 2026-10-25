# Linux app instructions

The Linux app is a Rust and GTK port of the macOS app in `../macos`. Keep its behavior, wording, and defaults the same unless Linux needs something different, and record such differences in `../docs/architecture.md`. Paths below are relative to `linux/`.

## Where it runs

Markus develops on the Mac and sometimes on a Linux machine. Git is the only sync between them, and each platform's changes are verified on that platform. A change to `../spec` or to both apps needs both: the macOS checks on a Mac, the Linux checks on a Linux machine.

- On a Linux machine, run the scripts below directly from the clone.
- On the Mac, `scripts/remote.sh <script> [arguments]` copies this checkout's `linux/` and `spec/`, uncommitted changes included, to `~/.cache/speakty-remote` on a Linux machine and runs a script from `scripts/` there. `scripts/remote.sh -- '<shell command>'` runs a command in that copy. Both run in the graphical session's environment, so GTK, Wayland, `hyprctl`, and the session bus work. The copy never touches a clone on that machine.
- The Linux machine is the SSH host `linux` (`mj-linux`, CachyOS with Hyprland, with the microphone). It isn't part of the fleet and is only on sometimes; when SSH fails, it's off, so leave the Linux checks for later and say so. Set `SPEAKTY_LINUX_HOST` to use another host.
- GitHub Actions runs the tests on every pull request and builds the release archive for every `v*` tag (`../.github/workflows/linux.yml`).
- Someone may be using the Linux machine: before a check that presses keys or opens windows, make sure no fullscreen app is focused (`hyprctl activewindow -j`). Checks run on workspace 9 and switch back.
- Its Hyprland config is Lua: dispatch with `hyprctl dispatch "hl.dsp.focus({ workspace = 9 })"`, not `hyprctl dispatch workspace 9`.
- Don't commit host-specific setup, such as Markus's kanata config, to this repository.

## Commands

- `scripts/test.sh [filter]` runs the unit tests and `../spec`'s transcript cases.
- `scripts/run.sh dev` builds and restarts Speakty Dev as the `speakty-dev` user unit, stopping the installed `speakty.service`. Run it after every successful change. `scripts/run.sh installed` switches back.
- `scripts/log.sh -n 50 --no-pager` prints the log of both units; without arguments it follows it.
- Releases cover both apps under one version and run on the Mac: `../scripts/release.sh`. Run it only when asked.

## Verifying changes

`src/bin/speakty-ui.rs` is the Linux `speakty-ui`: `hold rsuper 3` holds a key on a virtual keyboard, `tap esc` taps one, `pad 20` opens a text window in front and prints what lands in it, `windows` lists the overlay and Settings with their geometry, `clipboard` prints the clipboard, and `duration file.wav` prints a recording's length.

- To dictate without speaking, set `debug.testAudioFile` in `~/.config/speakty-dev/settings.json` to a WAV file. Speakty Dev replays it instead of the microphone and reads it at the start of every dictation. Make recordings on the Mac with `say -o speech.wav --data-format=LEF32@16000 "…"` and copy them over.
- `scripts/dictate.sh <recording.wav> [terminal]` sets the file, holds Right Super for its length, and prints what Speakty Dev pasted into the pad, or into a kitty window with `terminal`.
- The replay skips PipeWire and the microphone. When a change touches recording, devices, or pasting, ask Markus to try it with his microphone.
- `speakty status` (the installed Speakty, linked in `~/.local/bin`) or `~/.local/share/speakty-dev/speakty status` (Speakty Dev) prints the phase, model, permissions, and update state. `speakty settings <pane>` opens a pane, such as `transcript`.
- Take screenshots with `grim -g "x,y wxh" file.png`, using geometry from `speakty-ui windows`, and copy them to the Mac to view them. The display is 5K at scale 2, so geometry is in logical pixels and screenshots are twice that.
- To check updates, package a version above the running one with `SPEAKTY_VERSION=0.x.y-test.1 scripts/package.sh`, sign it on the Mac with `macos/Scripts/sparkle.sh sign_update -p <archive>`, write a manifest like the release's `speakty-linux.json` with a local path as `url`, set `debug.updateFeedURL` to the manifest's path, and run `speakty update` on Speakty Dev. Speakty Dev updates only from such a feed. It relaunches into the installed Speakty, so roll back with `speakty install --rollback` and delete the test version from `~/.local/share/speakty/versions` afterwards.

### Clean up

Afterwards, remove `debug` from Speakty Dev's settings, stop `speakty-dev`, and run `scripts/run.sh installed`, unless Markus asked for Speakty Dev.
