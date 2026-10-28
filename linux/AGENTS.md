# Linux app instructions

The Linux app is a Rust and GTK port of the macOS app in `../macos`. Keep its behavior, wording, and defaults the same unless Linux needs something different, and record such differences in `../docs/architecture.md`. Paths below are relative to `linux/`.

## Where it runs

Markus develops on the Mac and sometimes on a Linux machine. Git is the only sync between them, and each platform's changes are verified on that platform. A change to `../spec` or to both apps needs both: the macOS checks on a Mac, the Linux checks on a Linux machine.

- On a Linux machine, run the scripts below directly from the clone.
- On the Mac, `scripts/remote.sh <script> [arguments]` copies this checkout's `linux/` and `spec/`, uncommitted changes included, to `~/.cache/speakty-remote` on a Linux machine and runs a script from `scripts/` there. `scripts/remote.sh -- '<shell command>'` runs a command in that copy. Both run in the graphical session's environment, so GTK, Wayland, the compositor's IPC, and the session bus work. The copy never touches a clone on that machine.
- GitHub Actions runs the tests on every pull request and builds the release archive for every `v*` tag (`../.github/workflows/linux.yml`).
- Don't commit host-specific setup, such as Markus's kanata config, to this repository.

There are two Linux machines:

| | Fleet machine `l1` (`mj-l1`) | Gaming machine `linux` (`mj-linux`) |
|---|---|---|
| System | Ubuntu Server 26.04, always on, headless | CachyOS with Hyprland, only on sometimes |
| Session | Headless Sway, the `speakty-test-session` user unit | Markus's desktop |
| Microphone | None, only the virtual one `scripts/dictate.sh` plays into | Vocaster One |
| `remote.sh` | The default | `SPEAKTY_LINUX_HOST=linux` |
| Checks | Tests, the recording path, transcription, pasting, Settings | Hyprland-specific behavior, the real microphone and devices |

- Run Linux checks on `l1`. Use the gaming machine for what only it has: Hyprland, the overlay's look on its display, the microphone, and its devices. When SSH to it fails, it's off: leave those checks for later and say so.
- Neither machine runs GNOME, which most Ubuntu users have and which differs from wlroots compositors in overlays and global shortcuts. Keep that in mind for Linux bug reports.
- `l1` transcribes slower than the gaming machine. Use it to check correctness, not timing.
- `scripts/setup-test-host.sh` set `l1` up and brings it up to date: packages, Rust, the `input` group, the uinput rule, and the session. Its session has no seat and draws with Pixman, so it reads the keyboards directly and renders without a GPU. Its variables live in `$XDG_RUNTIME_DIR/speakty-test-session.env`, not in the user manager, so that other user services on the fleet machine don't land in it.
- `l1` also runs an X11 session for computer use. Speakty's checks don't use it.
- Someone may be using the gaming machine: before a check that presses keys or opens windows there, make sure no fullscreen app is focused (`speakty-ui front`). Checks run on workspace 9 and switch back.
- Its Hyprland config is Lua: dispatch with `hyprctl dispatch "hl.dsp.focus({ workspace = 9 })"`, not `hyprctl dispatch workspace 9`. `speakty-ui workspace` and `windows` handle both compositors.

## Commands

- `scripts/test.sh [filter]` runs the unit tests and `../spec`'s transcript cases.
- `scripts/run.sh dev` builds and restarts Speakty Dev as the `speakty-dev` user unit, stopping the installed `speakty.service`. Run it after every successful change. `scripts/run.sh installed` switches back.
- `scripts/log.sh -n 50 --no-pager` prints the log of both units; without arguments it follows it.
- Releases cover both apps under one version and run on the Mac: `../scripts/release.sh`. Run it only when asked.

## Verifying changes

`src/bin/speakty-ui.rs` is the Linux `speakty-ui`: `hold rsuper 3` holds a key on a virtual keyboard, `tap esc` taps one, `pad 20` opens a text window in front and prints what lands in it, `windows` lists Settings with its geometry, and the overlay on Hyprland, `front` prints the focused app, `workspace [n]` prints or switches the workspace, `clipboard` prints the clipboard, and `duration` and `channels` describe a WAV file.

- `scripts/dictate.sh <recording.wav> [terminal]` dictates a recording without speaking: it plays the file into a virtual PipeWire microphone with the file's channels, points Speakty Dev at it with `debug.microphone`, holds Right Super, and prints what Speakty Dev pasted into the pad, or into a kitty window with `terminal`. It removes the microphone and the setting afterwards.
- Markus's real dictations are in `~/.local/share/speakty-dictations` on both machines: `NN.wav`, recorded with the Vocaster's channels, and `NN.txt`, the sentence he read. They stay out of this public repository. `scripts/record-dictations.sh` records them on the gaming machine. For synthetic ones, run `say -o speech.wav --data-format=LEF32@16000 "…"` on the Mac and copy them over.
- The recording path is the real one up to PipeWire. When a change touches the microphone itself or other devices, ask Markus to try it on the gaming machine.
- `speakty status` (the installed Speakty, linked in `~/.local/bin`) or `~/.local/share/speakty-dev/speakty status` (Speakty Dev) prints the phase, model, permissions, and update state. `speakty settings <pane>` opens a pane, such as `transcript`.
- Take screenshots with `grim -g "x,y wxh" file.png`, using geometry from `speakty-ui windows`, and copy them to the Mac to view them. The gaming machine's display is 5K at scale 2, so geometry is in logical pixels and screenshots are twice that. `l1`'s display is a 1920x1080 headless output at scale 1.
- To check updates, package a version above the running one with `SPEAKTY_VERSION=0.x.y-test.1 scripts/package.sh`, sign it on the Mac with `macos/Scripts/sparkle.sh sign_update -p <archive>`, write a manifest like the release's `speakty-linux.json` with a local path as `url`, set `debug.updateFeedURL` to the manifest's path, and run `speakty update` on Speakty Dev. Speakty Dev updates only from such a feed. It relaunches into the installed Speakty, so roll back with `speakty install --rollback` and delete the test version from `~/.local/share/speakty/versions` afterwards.

### Clean up

Afterwards, remove `debug` from Speakty Dev's settings. On the gaming machine, stop `speakty-dev` and run `scripts/run.sh installed`, unless Markus asked for Speakty Dev. On `l1`, Speakty Dev can keep running.
