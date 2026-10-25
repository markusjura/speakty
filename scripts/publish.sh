#!/bin/zsh
# Publishes version <version> of both apps as the GitHub release v<version>, marked latest, which both
# updaters read through releases/latest:
#   macOS: the DMG and its checksum for people, and the ZIP with a signed appcast.xml for Sparkle.
#   Linux: the archive and its checksum, and speakty-linux.json, the manifest the Linux updater reads.
# The Linux archive comes from the GitHub Actions run for tag v<version>, which this waits for. Both
# updates are signed here with Sparkle's key from the login keychain, which never leaves the Mac.
# Usage: scripts/publish.sh <version>
# scripts/release.sh runs it last. Run it alone to retry a failed publish; it updates an existing release.
# Needs tag v<version> on origin and macos/.build/releases/Speakty-<version>.dmg and .zip from macos/Scripts/package.sh.
set -euo pipefail
cd "${0:A:h:h}"

fail() { print -u2 "$1"; exit 1 }
[[ $# -eq 1 ]] || fail "Usage: scripts/publish.sh <version>"
version="$1" tag="v$1"
dmg="macos/.build/releases/Speakty-$version.dmg"
zip="macos/.build/releases/Speakty-$version.zip"
sparkle=macos/Scripts/sparkle.sh

for file in $dmg $zip; do
  [[ -f "$file" && -f "$file.sha256" ]] || fail "$file or its checksum is missing. Run macos/Scripts/package.sh on the release commit."
  (cd "${file:h}" && shasum -a 256 -c "${file:t}.sha256" >/dev/null) || fail "Checksum mismatch for $file."
done
[[ -n "$(git ls-remote --tags origin "refs/tags/$tag")" ]] || fail "Tag $tag is not on origin."
git fetch --quiet --tags origin

# Installed copies accept only updates signed with the key their app names.
info() { unzip -p "$zip" Speakty.app/Contents/Info.plist | plutil -extract "$1" raw -o - - }
[[ "$(info CFBundleVersion)" == "$version" ]] || fail "$zip is not version $version."
[[ "$($sparkle generate_keys -p)" == "$(info SUPublicEDKey)" ]] ||
  fail "The login keychain has no Sparkle key matching SUPublicEDKey in $zip."

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The Linux archive, built in GitHub Actions from the tag.
commit=$(git rev-list -n 1 "$tag")
run=""
for _ in {1..60}; do
  run=$(gh run list --workflow linux.yml --commit "$commit" --event push --json databaseId,headBranch \
    --jq "map(select(.headBranch == \"$tag\")) | first | .databaseId // empty")
  [[ -n "$run" ]] && break
  sleep 5
done
[[ -n "$run" ]] || fail "No Linux build started for $tag. Check the Linux workflow in GitHub Actions."
print "Waiting for the Linux build…"
gh run watch "$run" --exit-status --interval 20 >/dev/null || fail "The Linux build for $tag failed: $(gh run view "$run" --json url --jq .url)"
gh run download "$run" --name speakty-linux --dir "$work"
archive="speakty-linux-$version-x86_64.tar.gz"
[[ -f "$work/$archive" ]] || fail "The Linux build has no $archive."
(cd "$work" && shasum -a 256 -c "$archive.sha256" >/dev/null) || fail "Checksum mismatch for $archive."

# Changes since the previous release, without version bumps, chores, and merges.
previous=$(git describe --tags --abbrev=0 --match 'v*' "$tag^" 2>/dev/null || true)
changes=$([[ -n "$previous" ]] && git log --no-merges --format='- %s' "$previous..$tag" | grep -v '^- chore' || true)

# The README's Install sections are the single copy of the install steps.
install=$(awk '/^## /{ found = ($0 == "## Install on macOS" || $0 == "## Install on Linux") } found' README.md)
[[ -n "$install" ]] || fail "README.md has no Install sections."
notes="${changes:+## Changes

$changes

}$install"

repo=$(gh repo view --json url --jq .url)
download="$repo/releases/download/$tag"

# Sparkle shows the changes as release notes. Settings links What's New to the release page. The feed lists only this release; Sparkle needs nothing older.
items=$(print -r -- "$changes" | sed -n -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's|^- \(.*\)|<li>\1</li>|p')
appcast="$work/appcast.xml"
cat > "$appcast" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Speakty</title>
    <item>
      <title>Speakty $version</title>
      <link>$repo/releases/tag/$tag</link>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$version</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$(info LSMinimumSystemVersion)</sparkle:minimumSystemVersion>
      ${items:+<description><![CDATA[<ul>$items</ul>]]></description>}
      <enclosure url="$download/${zip:t}" type="application/octet-stream" $($sparkle sign_update "$zip") />
    </item>
  </channel>
</rss>
XML
xmllint --noout "$appcast" || fail "The generated appcast is not valid XML."

jq -n --arg version "$version" --arg url "$download/$archive" --argjson length "$(stat -f %z "$work/$archive")" \
  --arg signature "$($sparkle sign_update -p "$work/$archive")" --arg notes "$repo/releases/tag/$tag" \
  '{version: $version, url: $url, length: $length, signature: $signature, notesUrl: $notes}' > "$work/speakty-linux.json"

files=($dmg "$dmg.sha256" $zip "$appcast" "$work/$archive" "$work/$archive.sha256" "$work/speakty-linux.json")
if gh release view "$tag" >/dev/null 2>&1; then
  gh release upload "$tag" $files --clobber
  gh release edit "$tag" --title "Speakty $version" --notes "$notes" --draft=false --latest >/dev/null
else
  gh release create "$tag" $files --verify-tag --latest --title "Speakty $version" --notes "$notes" >/dev/null
fi
print "Published $(gh release view "$tag" --json url --jq .url)"
