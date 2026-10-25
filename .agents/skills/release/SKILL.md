---
name: release
description: Use when asked to release or publish the app, or when `release` is written as a workflow command.
---

## Arguments

- Optional bump: `patch` (default), `minor`, `major`, or an exact `X.Y.Z` above the current version.

## Process

1. Run `scripts/release.sh [bump]` from a clean tree whose HEAD contains `origin/main`. It bumps `Version.xcconfig`, pushes `chore: release <version>` and tag `v<version>` to `main`, which starts the Linux build in GitHub Actions, packages the macOS ZIP and DMG, installs and launches the app from `/Applications`, then waits for the Linux build and publishes one GitHub release with both apps and the files both updaters read.
2. If a step after the push fails, fix the cause and run only the remaining steps the script prints. To retry only publishing, run `scripts/publish.sh <version>`. Never rerun `release.sh` for the same release; it would bump again.
3. When the Linux machine (SSH host `linux`) is on, install the release there with `speakty update`, or let it update itself.

Completes when the GitHub release URL is confirmed and the installed macOS app reports the new version.

## Response

Return the version, release URL, and any blocker.
