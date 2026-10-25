# Linux app instructions

The Linux app is a Rust and GTK port of the macOS app in `../macos`. Keep its behavior, wording, and defaults the same unless Linux needs something different, and record such differences in `../docs/architecture.md`. Paths below are relative to `linux/`.

## The Linux machine

- Development happens on the Mac; building and testing happen on the Linux machine, the SSH host `linux` (`mj-linux`, CachyOS with Hyprland). It isn't part of the fleet. Set `SPEAKTY_LINUX_HOST` to use another host.
- `scripts/remote.sh <script> [arguments]` copies this checkout's `linux/` and `spec/` to `~/src/speakty` there and runs a script from `scripts/`. `scripts/remote.sh -- '<shell command>'` runs a command in that copy. Both run in the graphical session's environment, so GTK, Wayland, `hyprctl`, and the session bus work. Every checkout and worktree shares the one copy.
- The machine stays logged in to Hyprland without a lock screen, so checks run unattended. Someone may be using it: before a check that presses keys or opens windows, make sure no fullscreen app is focused (`hyprctl activewindow -j`). Checks run on workspace 9 and switch back.
- This Hyprland config is Lua: dispatch with `hyprctl dispatch "hl.dsp.focus({ workspace = 9 })"`, not `hyprctl dispatch workspace 9`.
- Voxtype is another dictation app on the machine that reacts to Right Super. While `voxtype.service` runs, stop it for a check and start it again afterwards. `scripts/dictate.sh` does this.
- Don't commit host-specific setup, such as the user's kanata or Voxtype config, to this repository.

## Commands

- `scripts/remote.sh test.sh [filter]` runs the unit tests and `../spec`'s transcript cases.
- `scripts/remote.sh run.sh dev` builds and restarts Speakty Dev as the `speakty-dev` user unit, stopping the installed `speakty.service`. Run it after every successful change. `scripts/remote.sh run.sh installed` switches back.
- `scripts/remote.sh log.sh -n 50 --no-pager` prints the log of both units; without arguments it follows it.
- Run `scripts/release.sh` and `scripts/publish.sh` only when asked. They run on the Mac, since the update signing key is Sparkle's, in the Mac's login keychain.

## Verifying changes

`src/bin/speakty-ui.rs` is the Linux `speakty-ui`: `hold rsuper 3` holds a key on a virtual keyboard, `tap esc` taps one, `pad 20` opens a text window in front and prints what lands in it, `windows` lists the overlay and Settings with their geometry, and `clipboard` prints the clipboard.

- To dictate without speaking, set `debug.testAudioFile` in `~/.config/speakty-dev/settings.json` to a WAV file. Speakty Dev replays it instead of the microphone and reads it at the start of every dictation. Make recordings on the Mac with `say -o speech.wav --data-format=LEF32@16000 "…"` and copy them over.
- `scripts/dictate.sh <recording.wav> [terminal]` sets the file, holds Right Super for its length, and prints what Speakty Dev pasted into the pad, or into a kitty window with `terminal`.
- `speakty status` (the installed Speakty, linked in `~/.local/bin`) or `~/.local/share/speakty-dev/speakty status` (Speakty Dev) prints the phase, model, permissions, and update state of the running Speakty. `speakty settings <pane>` opens a pane, such as `transcript`.
- Take screenshots with `grim -g "x,y wxh" file.png`, using geometry from `speakty-ui windows`, and copy them to the Mac to view them. The display is 5K at scale 2, so geometry is in logical pixels and screenshots are twice that.
- To check updates, package a version above the running one with `SPEAKTY_VERSION=0.x.y-test.1 scripts/package.sh`, sign it on the Mac with `scripts/sign.sh`, write a manifest like the release's `speakty-linux.json` with a local path as `url`, set `debug.updateFeedURL` to the manifest's path, and run `speakty update` on Speakty Dev. Speakty Dev updates only from such a feed. It relaunches into the installed Speakty, so roll back with `speakty install --rollback` and delete the test version from `~/.local/share/speakty/versions` afterwards.

### Clean up

Afterwards, remove `debug` from Speakty Dev's settings, stop `speakty-dev`, and run `scripts/remote.sh run.sh installed`, unless Markus asked for Speakty Dev. Start `voxtype.service` again only if it was running before.
