#!/usr/bin/env bash
# Builds the release binary and packages it as target/releases/speakty-linux-<version>-x86_64.tar.gz,
# with a .sha256 beside it. The archive holds speakty/speakty, which `speakty install` installs.
# Usage: scripts/package.sh
# On a clean checkout of tag linux-v<version>, the version is Cargo.toml's. Anywhere else it's
# <version>-dev.g<commit>, which sorts below the release, so the release replaces it. remote.sh passes
# the commit as SPEAKTY_COMMIT, since its copy has no history. SPEAKTY_VERSION overrides both, for tests.
set -euo pipefail
cd "$(dirname "$0")/.."

version=$(sed -n 's/^version = "\(.*\)"/\1/p' Cargo.toml | head -1)
if [[ -n "${SPEAKTY_VERSION:-}" ]]; then
  version=$SPEAKTY_VERSION
elif [[ "$(git describe --exact-match --tags 2>/dev/null)" != "linux-v$version" || -n "$(git status --porcelain 2>/dev/null)" ]]; then
  version+="-dev.g${SPEAKTY_COMMIT:-$(git rev-parse --short HEAD)}"
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
