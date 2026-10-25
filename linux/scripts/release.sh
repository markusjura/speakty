#!/bin/zsh
# Releases Speakty for Linux from the Mac: bumps the version, pushes it to main with tag
# linux-v<version>, builds the archive on the Linux machine, signs it with Sparkle's key from the login
# keychain, and publishes the GitHub release that installed copies update from.
# Usage: linux/scripts/release.sh [patch|minor|major|X.Y.Z]
# Run it only when asked. To retry only the publishing after the push, run linux/scripts/publish.sh <version>.
set -euo pipefail
cd "${0:A:h:h:h}"

fail() { print -u2 "$1"; exit 1 }
usage="Usage: linux/scripts/release.sh [patch|minor|major|X.Y.Z]"
manifest=linux/Cargo.toml

[[ $# -le 1 ]] || fail "$usage"
[[ -z "$(git status --porcelain)" ]] || fail "Commit or stash your changes first."
git fetch --quiet --tags origin main
git merge-base --is-ancestor origin/main HEAD || fail "HEAD doesn't contain origin/main. Rebase onto it first."

current=$(sed -n 's/^version = "\(.*\)"/\1/p' $manifest | head -1)
[[ "$current" == <->.<->.<-> ]] || fail "No X.Y.Z version in $manifest."
parts=(${(s:.:)current})
case "${1:-patch}" in
  patch) next="$parts[1].$parts[2].$(( parts[3] + 1 ))" ;;
  minor) next="$parts[1].$(( parts[2] + 1 )).0" ;;
  major) next="$(( parts[1] + 1 )).0.0" ;;
  <->.<->.<->) next="$1" ;;
  *) fail "$usage" ;;
esac
# The first release keeps the version Cargo.toml starts with.
[[ -z "$(git tag --list 'linux-v*')" && $# -eq 0 ]] && next=$current
autoload -Uz is-at-least
is-at-least "$current" "$next" || fail "$next is below the current $current."
[[ -z "$(git tag --list "linux-v$next")" ]] || fail "Tag linux-v$next already exists."
linux/scripts/sign.sh --check || fail "The login keychain has no Sparkle key matching the updater's."

if [[ "$next" != "$current" ]]; then
  sed -i '' "1,/^version = /s/^version = \".*\"/version = \"$next\"/" $manifest
  linux/scripts/remote.sh -- 'cargo update --quiet --workspace --offline'
  scp -q "${SPEAKTY_LINUX_HOST:-linux}:src/speakty/linux/Cargo.lock" linux/Cargo.lock
  git commit --quiet -m "chore: release Linux $next" $manifest linux/Cargo.lock
fi
git tag "linux-v$next"
git push --quiet --atomic origin HEAD:main "linux-v$next" ||
  fail "Push failed. Undo the local release with: git tag -d linux-v$next && git reset --keep HEAD~1"

trap 'print -u2 "Pushed linux-v$next, but a step failed. Fix it, then run: linux/scripts/publish.sh $next"' ERR
linux/scripts/publish.sh "$next"
