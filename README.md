# Speakty

A minimal native macOS dictation app tailored to Markus's workflow, from the same family as Shotty and Spotty. Hold Right ⌘, speak, let go, and the transcript is pasted where you're typing. Or tap Right ⌘ to start and again to stop. Transcription runs on this Mac with Parakeet Ultra on the Neural Engine. No accounts, cloud models, or telemetry.

## Install

Speakty needs macOS 26 or later on Apple Silicon.

1. Download the DMG from the [latest release](https://github.com/markusjura/speakty/releases/latest) and open it.
2. Drag Speakty onto Applications.
3. Open Speakty from Applications. macOS says it can't verify Speakty, because Speakty isn't notarized by Apple. Click Done.
4. Open System Settings > Privacy & Security, click Open Anyway next to the message about Speakty, and confirm with your password.

Speakty runs from the menu bar. On first launch it opens Settings on Permissions, where you allow the microphone and Accessibility, and it downloads the dictation model (about 630 MB) in the background.

## Build and test

Requires an Apple Silicon Mac, macOS 26 or later, Xcode 27, and an Apple Development signing identity. To build on a second Mac, import that identity's certificate and private key instead of letting Xcode create a new certificate, so both sign with the same designated requirement. Create a gitignored `Local.xcconfig` in the repository root containing `DEVELOPMENT_TEAM = YOUR_TEAM_ID`. The shared project includes it through `Config/Signing.xcconfig`; no certificate or private key belongs in the repository.

Open `Speakty.xcodeproj` and select the shared Speakty scheme, or run:

```sh
Scripts/xcode.sh release build
Scripts/test.sh
Scripts/run.sh dev
```

`Scripts/xcode.sh release build` builds the signed Release app at `.build/Build/Products/Release/Speakty.app`. The target uses Hardened Runtime and no App Sandbox. Its only entitlement, audio input in `Config/Speakty.entitlements`, lets Hardened Runtime record the microphone. This is private Apple Development signing, not a notarized Developer ID release, so a copied build may not launch as trusted on another Mac.

`Scripts/GenerateAppIcon.swift` draws the app icon. Run `swift Scripts/GenerateAppIcon.swift` after changing it.

## Develop

```sh
Scripts/run.sh dev        # build Debug and switch to ~/Applications/Speakty Dev.app
Scripts/run.sh installed  # switch back to /Applications/Speakty.app
```

The Debug build is Speakty Dev, bundle ID `local.markus.Speakty.dev`. It has its own preferences and permission grants, so it never touches the installed Speakty's settings, and Spotlight and Raycast list it separately. `run.sh dev` copies the build to `~/Applications/Speakty Dev.app` and launches that copy, because Spotlight doesn't index the hidden `.build` folder. Every checkout and worktree replaces the same copy. The two share the dictation shortcut, so only one runs: `run.sh` quits both before launching one, and Speakty Dev quits the installed build when it launches and quits itself when the installed build launches. That check exists only in Debug builds. Both builds share the downloaded models in `~/Library/Application Support/FluidAudio`. To start Speakty Dev with your current settings, run `defaults export local.markus.Speakty - | defaults import local.markus.Speakty.dev -` while both are quit.

## Package, install, and roll back

`Scripts/release.sh [patch|minor|major|X.Y.Z]` bumps `MARKETING_VERSION` in `Config/Version.xcconfig`, patch by default, commits `chore: release <version>`, and pushes it to `main` with tag `v<version>`. It then packages, installs, and launches the release with the scripts below and publishes it on GitHub. `CURRENT_PROJECT_VERSION` equals `MARKETING_VERSION`, so the version alone identifies a release.

`Scripts/package.sh` refuses to run unless the working tree is clean and `HEAD` is `origin/main`, so each version names one pushed commit. It builds Release, refuses to continue unless `codesign --verify --deep --strict` passes and the bundle ID is `local.markus.Speakty`, and writes to `.build/releases/`:

- `Speakty-<version>.zip`, created with `ditto` so the signature survives. `install.sh` and Sparkle updates use it.
- `Speakty-<version>.dmg`, built by `uvx dmgbuild` from `Config/dmg.py`. It opens to a window for dragging Speakty onto Applications. `swift Scripts/GenerateDMGBackground.swift Config` redraws its background.
- A `.sha256` checksum beside each.
- A `.txt` record of the signing authority, team, designated requirement, and entitlements.

`Scripts/publish.sh <version>` creates or updates the GitHub release for tag `v<version>` with the DMG and its checksum, plus the signed ZIP and `appcast.xml` that installed copies update from through Sparkle. The notes list the commits since the previous tag, without chores, followed by the Install section of this README.

To install on the same Mac, run `Scripts/install.sh .build/releases/Speakty-<version>.zip`. It refuses a version older than the installed one and asks a running Speakty to quit first, like its Quit menu item.

The installer checks the checksum when the `.sha256` file is present, verifies the signature and bundle ID, and warns before installing a build whose designated requirement differs from the installed one, because macOS ties permission grants to it. It replaces `/Applications/Speakty.app` by renaming and keeps the replaced build at `~/Library/Application Support/Speakty Installer.noindex/Speakty.previous.app`. `Scripts/install.sh --rollback` swaps the two. Settings in UserDefaults are never touched.

## Permissions

Grant permissions to the installed `/Applications/Speakty.app`. Speakty Dev has its own bundle ID, so it needs its own grants once; they then survive rebuilds. Grants are per Mac; signing does not carry them to another machine.

- **Microphone** records your voice while you dictate. Speakty asks the first time you dictate.
- **Accessibility** lets Speakty paste with ⌘V and watch a modifier key such as Right ⌘ as the shortcut. Without it, a shortcut with a key, such as ⌃⌥D, still works, and transcripts land on the clipboard instead of being pasted.
- Input Monitoring, Screen Recording, and every other permission are not needed.

Keeping the bundle ID and signing identity stable keeps the grants across updates.
