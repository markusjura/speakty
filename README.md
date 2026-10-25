# Speakty

A minimal dictation app tailored to Markus's workflow, from the same family as Shotty and Spotty. Hold Right ⌘, speak, let go, and the transcript is pasted where you're typing. Or tap Right ⌘ to start and again to stop. Transcription runs on your computer with Parakeet Ultra. No accounts, cloud models, or telemetry.

The macOS app in `macos/` is native Swift and runs the model on the Neural Engine. The Linux app in `linux/` is Rust and GTK and runs the same model on the CPU; its shortcut is Right Super. `spec/` holds the transcript cases both apps test against. `docs/architecture.md` describes both.

## Install on macOS

Speakty needs macOS 26 or later on Apple Silicon.

1. Download the DMG from the [latest release](https://github.com/markusjura/speakty/releases/latest) and open it.
2. Drag Speakty onto Applications.
3. Open Speakty from Applications. macOS says it can't verify Speakty, because Speakty isn't notarized by Apple. Click Done.
4. Open System Settings > Privacy & Security, click Open Anyway next to the message about Speakty, and confirm with your password.

Speakty runs from the menu bar. On first launch it opens Settings on Permissions, where you allow the microphone and Accessibility, and it downloads the dictation model (about 630 MB) in the background.

## Install on Linux

Speakty for Linux needs a Wayland compositor with the data-control protocol, such as Hyprland, Sway, or KDE Plasma, plus PipeWire and GTK 4 with libadwaita and gtk4-layer-shell. It's built and tested on CachyOS with Hyprland, on x86-64.

1. Allow Speakty to read the keyboards and to type the paste, once, then log out and in again:
   ```sh
   sudo usermod -aG input $USER
   echo 'KERNEL=="uinput", GROUP="input", MODE="0660", OPTIONS+="static_node=uinput"' | sudo tee /etc/udev/rules.d/70-speakty-uinput.rules
   sudo udevadm control --reload && sudo udevadm trigger /dev/uinput
   ```
2. Download `speakty-linux-<version>-x86_64.tar.gz` from the [latest release](https://github.com/markusjura/speakty/releases/latest).
3. Run `tar xzf speakty-linux-*.tar.gz && speakty/speakty install`.

The installer puts Speakty in `~/.local/share/speakty`, without root, links `~/.local/bin/speakty` to it, and starts it as the `speakty.service` user unit with the graphical session. Open Settings from your app launcher or with `speakty settings`. It downloads the dictation model (about 670 MB) on first launch, and later versions install themselves. `speakty install --rollback` goes back to the previous version. Members of the `input` group can read every keystroke, so grant it only on a computer you trust.

## Build and test on macOS

Requires an Apple Silicon Mac, macOS 26 or later, Xcode 27, and an Apple Development signing identity. To build on a second Mac, import that identity's certificate and private key instead of letting Xcode create a new certificate, so both sign with the same designated requirement. Create a gitignored `Local.xcconfig` in the repository root containing `DEVELOPMENT_TEAM = YOUR_TEAM_ID`. The shared project includes it through `macos/Config/Signing.xcconfig`; no certificate or private key belongs in the repository.

Open `macos/Speakty.xcodeproj` and select the shared Speakty scheme, or run:

```sh
macos/Scripts/xcode.sh release build
macos/Scripts/test.sh
macos/Scripts/run.sh dev
```

`macos/Scripts/xcode.sh release build` builds the signed Release app at `macos/.build/Build/Products/Release/Speakty.app`. The target uses Hardened Runtime and no App Sandbox. Its only entitlement, audio input in `macos/Config/Speakty.entitlements`, lets Hardened Runtime record the microphone. This is private Apple Development signing, not a notarized Developer ID release, so a copied build may not launch as trusted on another Mac.

`macos/Scripts/GenerateAppIcon.swift` draws the app icon. Run `swift macos/Scripts/GenerateAppIcon.swift` after changing it.

## Develop on macOS

```sh
macos/Scripts/run.sh dev        # build Debug and switch to ~/Applications/Speakty Dev.app
macos/Scripts/run.sh installed  # switch back to /Applications/Speakty.app
```

The Debug build is Speakty Dev, bundle ID `local.markus.Speakty.dev`. It has its own preferences and permission grants, so it never touches the installed Speakty's settings, and Spotlight and Raycast list it separately. `run.sh dev` copies the build to `~/Applications/Speakty Dev.app` and launches that copy, because Spotlight doesn't index the hidden `.build` folder. Every checkout and worktree replaces the same copy. The two share the dictation shortcut, so only one runs: `run.sh` quits both before launching one, and Speakty Dev quits the installed build when it launches and quits itself when the installed build launches. That check exists only in Debug builds. Both builds share the downloaded models in `~/Library/Application Support/FluidAudio`. To start Speakty Dev with your current settings, run `defaults export local.markus.Speakty - | defaults import local.markus.Speakty.dev -` while both are quit.

## Package, install, and roll back on macOS

Releases cover both apps under one version, `MARKETING_VERSION` in `Version.xcconfig` at the repository root. `scripts/release.sh [patch|minor|major|X.Y.Z]` runs on the Mac. It bumps the version, patch by default, commits `chore: release <version>`, and pushes it to `main` with tag `v<version>`. The tag starts the Linux build in GitHub Actions. The script then packages, installs, and launches the macOS app with the scripts below and publishes the release with `scripts/publish.sh`. `CURRENT_PROJECT_VERSION` equals `MARKETING_VERSION`, so the version alone identifies a release.

`macos/Scripts/package.sh` refuses to run unless the working tree is clean and `HEAD` is `origin/main`, so each version names one pushed commit. It builds Release, refuses to continue unless `codesign --verify --deep --strict` passes and the bundle ID is `local.markus.Speakty`, and writes to `macos/.build/releases/`:

- `Speakty-<version>.zip`, created with `ditto` so the signature survives. `install.sh` and Sparkle updates use it.
- `Speakty-<version>.dmg`, built by `uvx dmgbuild` from `macos/Config/dmg.py`. It opens to a window for dragging Speakty onto Applications. `swift macos/Scripts/GenerateDMGBackground.swift macos/Config` redraws its background.
- A `.sha256` checksum beside each.
- A `.txt` record of the signing authority, team, designated requirement, and entitlements.

`scripts/publish.sh <version>` waits for the Linux build of tag `v<version>` and downloads its archive. It signs the macOS ZIP and the Linux archive with Sparkle's key from the login keychain, then creates or updates the GitHub release `v<version>`, marked latest. The release holds the DMG and its checksum, the signed ZIP and `appcast.xml` that macOS copies update from through Sparkle, and the Linux archive, its checksum, and `speakty-linux.json`, the manifest Linux copies update from. Both updaters read the latest release. The notes list the commits since the previous tag, without chores, followed by the README's Install sections.

To install on the same Mac, run `macos/Scripts/install.sh macos/.build/releases/Speakty-<version>.zip`. It refuses a version older than the installed one and asks a running Speakty to quit first, like its Quit menu item.

The installer checks the checksum when the `.sha256` file is present, verifies the signature and bundle ID, and warns before installing a build whose designated requirement differs from the installed one, because macOS ties permission grants to it. It replaces `/Applications/Speakty.app` by renaming and keeps the replaced build at `~/Library/Application Support/Speakty Installer.noindex/Speakty.previous.app`. `macos/Scripts/install.sh --rollback` swaps the two. Settings in UserDefaults are never touched.

## Permissions on macOS

Grant permissions to the installed `/Applications/Speakty.app`. Speakty Dev has its own bundle ID, so it needs its own grants once; they then survive rebuilds. Grants are per Mac; signing does not carry them to another machine.

- **Microphone** records your voice while you dictate. Speakty asks the first time you dictate.
- **Accessibility** lets Speakty paste with ⌘V and watch a modifier key such as Right ⌘ as the shortcut. Without it, a shortcut with a key, such as ⌃⌥D, still works, and transcripts land on the clipboard instead of being pasted.
- Input Monitoring, Screen Recording, and every other permission are not needed.

Keeping the bundle ID and signing identity stable keeps the grants across updates.

## Build, test, and release on Linux

`linux/AGENTS.md` describes the workflow, including driving the Linux machine from the Mac with `linux/scripts/remote.sh`. Builds need Rust 1.92 or later and the development files of GTK 4, libadwaita, gtk4-layer-shell, and PipeWire. `cargo build` downloads sherpa-onnx with ONNX Runtime and links them statically, so the binary needs no ONNX Runtime on the system.

```sh
linux/scripts/test.sh          # unit tests and the shared transcript cases
linux/scripts/run.sh dev       # build and run Speakty Dev as the speakty-dev user unit
linux/scripts/package.sh       # build linux/target/releases/speakty-linux-<version>-x86_64.tar.gz
linux/scripts/install.sh <archive>
```

Debug builds are Speakty Dev, app ID `local.markus.Speakty.dev`, with their own settings in `~/.config/speakty-dev`. They share the models with the installed Speakty.

GitHub Actions runs the Linux tests on every pull request and builds the release archive for every `v*` tag in a Debian 13 container, whose older libraries make the binary run on rolling distributions too. Releases cover both apps; see Package, install, and roll back on macOS.
