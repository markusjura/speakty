#!/bin/zsh
# Releases Speakty for macOS and Linux under one version: bumps it, pushes it to main with tag
# v<version>, packages, installs, and launches the macOS app, then publishes both on GitHub. The tag
# push starts the Linux build in GitHub Actions, which publish.sh waits for.
# Usage: scripts/release.sh [patch|minor|major|X.Y.Z]
#   patch (default) 0.1.0 → 0.1.1, minor 0.1.4 → 0.2.0, major 0.2.0 → 1.0.0, or an exact higher version.
# Runs on a Mac with the signing identity and the Sparkle key. Run it only when asked.
set -euo pipefail
cd "${0:A:h:h}"

fail() { print -u2 "$1"; exit 1 }
usage="Usage: scripts/release.sh [patch|minor|major|X.Y.Z]"
config=Version.xcconfig

[[ $# -le 1 ]] || fail "$usage"
[[ -z "$(git status --porcelain)" ]] || fail "Commit or stash your changes first."
git fetch --quiet --tags origin main
git merge-base --is-ancestor origin/main HEAD || fail "HEAD doesn't contain origin/main. Rebase onto it first."

current=$(sed -n 's/^MARKETING_VERSION = //p' $config)
[[ "$current" == <->.<->.<-> ]] || fail "No X.Y.Z MARKETING_VERSION in $config."
parts=(${(s:.:)current})
case "${1:-patch}" in
  patch) next="$parts[1].$parts[2].$(( parts[3] + 1 ))" ;;
  minor) next="$parts[1].$(( parts[2] + 1 )).0" ;;
  major) next="$(( parts[1] + 1 )).0.0" ;;
  <->.<->.<->) next="$1" ;;
  *) fail "$usage" ;;
esac
# Installs and both updaters order releases by version, so it only ever goes up.
autoload -Uz is-at-least
[[ "$next" != "$current" ]] && is-at-least "$current" "$next" || fail "$next is not above the current $current."
[[ -z "$(git tag --list "v$next")" ]] || fail "Tag v$next already exists."
# Publishing signs both updates with Sparkle's key, so make sure it can before the version is taken.
[[ "$(macos/Scripts/sparkle.sh generate_keys -p)" == "$(plutil -extract SUPublicEDKey raw macos/Config/Info.plist)" ]] ||
  fail "The login keychain has no Sparkle key matching SUPublicEDKey in macos/Config/Info.plist."

sed -i '' "s/^MARKETING_VERSION = .*/MARKETING_VERSION = $next/" $config
git commit --quiet -m "chore: release $next" $config
git tag "v$next"
# Atomic, so main never gets the bump without its tag or the other way round.
git push --quiet --atomic origin HEAD:main "v$next" ||
  fail "Push failed. Undo the local release with: git tag -d v$next && git reset --keep HEAD~1"

# From here on the version is taken, so a failure is finished by hand, not by releasing again.
trap 'print -u2 "Pushed $next, but a step failed. Fix it, then run the remaining steps of: macos/Scripts/package.sh, macos/Scripts/install.sh macos/.build/releases/Speakty-$next.zip, macos/Scripts/run.sh installed, scripts/publish.sh $next"' ERR
macos/Scripts/package.sh
macos/Scripts/install.sh "macos/.build/releases/Speakty-$next.zip"
macos/Scripts/run.sh installed
scripts/publish.sh "$next"
