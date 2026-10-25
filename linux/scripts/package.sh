#!/usr/bin/env bash
# Builds the release binary and packages it as target/releases/speakty-linux-<version>-x86_64.tar.gz,
# with a .sha256 beside it. The archive holds speakty/speakty, which `speakty install` installs.
# Usage: scripts/package.sh
# The version is ../Version.xcconfig's on a clean checkout of tag v<version>, and <version>+dev.g<commit>
# anywhere else, which the release of <version> doesn't replace. remote.sh passes the commit as
# SPEAKTY_COMMIT, since its copy has no history. SPEAKTY_VERSION overrides both, as release builds do.
set -euo pipefail
cd "$(dirname "$0")/.."

version=$(sed -n 's/^MARKETING_VERSION = //p' ../Version.xcconfig)
if [[ -n "${SPEAKTY_VERSION:-}" ]]; then
  version=$SPEAKTY_VERSION
elif [[ -n "${SPEAKTY_COMMIT:-}" || "$(git describe --exact-match --tags 2>/dev/null)" != "v$version" || -n "$(git status --porcelain 2>/dev/null)" ]]; then
  version+="+dev.g${SPEAKTY_COMMIT:-$(git rev-parse --short HEAD)}"
fi
SPEAKTY_VERSION=$version cargo build --release --locked --bin speakty
[[ "$(target/release/speakty version)" == "Speakty $version" ]] || { echo "The build reports another version." >&2; exit 1; }

releases=target/releases
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$releases" "$work/speakty"
install -m 755 target/release/speakty "$work/speakty/speakty"
archive="$releases/speakty-linux-$version-x86_64.tar.gz"
tar -C "$work" --owner=0 --group=0 -czf "$archive" speakty
(cd "$releases" && sha256sum "$(basename "$archive")" > "$(basename "$archive").sha256")
echo "$archive"
