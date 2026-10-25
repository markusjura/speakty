#!/usr/bin/env bash
# Installs a packaged Speakty for the current user and restarts its service. Later versions arrive
# through Speakty's own updater.
# Usage: scripts/install.sh path/to/speakty-linux-<version>-x86_64.tar.gz
#        scripts/install.sh --rollback   # go back to the previous version
set -euo pipefail

if [[ "${1:-}" == --rollback ]]; then
  exec ~/.local/share/speakty/current/speakty install --rollback
fi
archive=${1:?Usage: scripts/install.sh <archive> | --rollback}
if [[ -f "$archive.sha256" ]]; then
  (cd "$(dirname "$archive")" && sha256sum --quiet -c "$(basename "$archive").sha256")
fi
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
tar -C "$work" -xzf "$archive"
"$work/speakty/speakty" install
