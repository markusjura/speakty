#!/usr/bin/env bash
# Switches between the development build, Speakty Dev, and the installed Speakty.
# Usage:
#   scripts/run.sh dev        # build, stop both, run Speakty Dev as the speakty-dev user unit
#   scripts/run.sh installed  # stop both, start the installed Speakty's speakty.service
# Speakty Dev has its own app ID, settings, and state, and shares the models. Both watch the same
# shortcut, so only one runs. Its desktop entry lets app launchers open its Settings.
set -euo pipefail
cd "$(dirname "$0")/.."

dev_home=~/.local/share/speakty-dev
stop() {
  systemctl --user stop speakty-dev.service 2>/dev/null || true
  systemctl --user stop speakty.service 2>/dev/null || true
}

case "${1:-}" in
  dev)
    # Build before stopping, so a failed build leaves the running Speakty alone.
    cargo build --bin speakty --bin speakty-ui
    stop
    mkdir -p "$dev_home" ~/.local/share/applications
    # A copy, so a later build never replaces the running binary.
    install -m 755 target/debug/speakty "$dev_home/speakty.new" && mv "$dev_home/speakty.new" "$dev_home/speakty"
    cat > ~/.local/share/applications/local.markus.Speakty.dev.desktop <<DESKTOP
[Desktop Entry]
Type=Application
Name=Speakty Dev
Exec=$dev_home/speakty settings
Icon=local.markus.Speakty
Categories=Utility;
StartupNotify=false
DESKTOP
    systemctl --user reset-failed speakty-dev.service 2>/dev/null || true
    systemd-run --user --quiet --unit=speakty-dev --collect "$dev_home/speakty"
    version=$("$dev_home/speakty" version)
    if git rev-parse --git-dir >/dev/null 2>&1; then version+=" @ $(git rev-parse --short HEAD)"; fi
    echo "Started $version as speakty-dev.service"
    ;;
  installed)
    stop
    [[ -x ~/.local/share/speakty/current/speakty ]] || { echo "Speakty isn't installed. Install a release with scripts/install.sh first." >&2; exit 1; }
    systemctl --user start speakty.service
    echo "Started $(~/.local/share/speakty/current/speakty version)"
    ;;
  *) echo "Usage: scripts/run.sh dev | installed" >&2; exit 1 ;;
esac
