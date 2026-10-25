#!/bin/zsh
# Builds, signs, and publishes Speakty for Linux <version> as the GitHub release linux-v<version>: the
# archive and its checksum, and speakty-linux.json, the manifest the updater reads. Runs on the Mac;
# the archive is built on the Linux machine from tag linux-v<version>.
# Linux releases are never marked latest, since the macOS app updates through releases/latest.
# Usage: linux/scripts/publish.sh <version>
# linux/scripts/release.sh runs it last. Run it alone to retry; it updates an existing release.
set -euo pipefail
cd "${0:A:h:h:h}"

fail() { print -u2 "$1"; exit 1 }
[[ $# -eq 1 ]] || fail "Usage: linux/scripts/publish.sh <version>"
version=$1 tag="linux-v$1" host=${SPEAKTY_LINUX_HOST:-linux}
[[ -n "$(git ls-remote --tags origin "refs/tags/$tag")" ]] || fail "Tag $tag is not on origin."
linux/scripts/sign.sh --check || fail "The login keychain has no Sparkle key matching the updater's."
git fetch --quiet --tags origin

# Build from the tag in a worktree of its own, so the archive is exactly the tagged source.
work=$(mktemp -d)
trap 'git worktree remove --force "$work/source" 2>/dev/null; rm -rf "$work"' EXIT
git worktree add --quiet --detach "$work/source" "$tag"
(cd "$work/source" && SPEAKTY_VERSION=$version linux/scripts/remote.sh package.sh)
archive="speakty-linux-$version-x86_64.tar.gz"
scp -q "$host:src/speakty/linux/target/releases/$archive" "$host:src/speakty/linux/target/releases/$archive.sha256" "$work/"
(cd "$work" && shasum -a 256 -c "$archive.sha256" >/dev/null) || fail "Checksum mismatch for $archive."

repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
signature=$(linux/scripts/sign.sh "$work/$archive")
jq -n --arg version "$version" --arg signature "$signature" --argjson length "$(stat -f %z "$work/$archive")" \
  --arg url "https://github.com/$repo/releases/download/$tag/$archive" \
  --arg notes "https://github.com/$repo/releases/tag/$tag" \
  '{version: $version, url: $url, length: $length, signature: $signature, notesUrl: $notes}' > "$work/speakty-linux.json"

# Changes since the previous Linux release, without chores, merges, and macOS-only commits.
previous=$(git describe --tags --abbrev=0 --match 'linux-v*' "$tag^" 2>/dev/null || true)
changes=$([[ -n "$previous" ]] && git log --no-merges --format='- %s' "$previous..$tag" -- . ':(exclude)macos' | grep -v '^- chore' || true)
install=$(awk '/^## /{ found = ($0 == "## Install on Linux") } found' README.md)
[[ -n "$install" ]] || fail "README.md has no ## Install on Linux section."
notes="${changes:+## Changes

$changes

}$install"

files=("$work/$archive" "$work/$archive.sha256" "$work/speakty-linux.json")
if gh release view "$tag" >/dev/null 2>&1; then
  gh release upload "$tag" $files --clobber
  gh release edit "$tag" --title "Speakty for Linux $version" --notes "$notes" --draft=false --latest=false >/dev/null
else
  gh release create "$tag" $files --verify-tag --latest=false --title "Speakty for Linux $version" --notes "$notes" >/dev/null
fi
print "Published $(gh release view "$tag" --json url --jq .url)"
