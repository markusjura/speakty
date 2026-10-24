#!/bin/zsh
# Switches between the development build, Speakty Dev, and the installed Speakty.
# Usage:
#   Scripts/run.sh dev        # build Debug, quit both, launch ~/Applications/Speakty Dev.app
#   Scripts/run.sh installed  # quit both, launch /Applications/Speakty.app
# Speakty Dev has its own bundle ID, preferences, and permission grants, so opening "Speakty" or
# "Speakty Dev" by name always starts that build. They share global shortcuts, so Speakty Dev quits the
# installed build when it launches and quits itself when the installed build launches.
set -euo pipefail
cd "${0:A:h:h}"

installed_id=local.markus.Speakty
dev_id=local.markus.Speakty.dev
fail() { print -u2 "$1"; exit 1 }
running() { [[ -n "$(lsappinfo find bundleid="$1")" ]] }

case "${1:-}" in
  dev)
    built="$PWD/.build/acceptance-tests/Build/Products/Debug/Speakty Dev.app"
    app=~/Applications/"Speakty Dev.app"
    # Build before quitting, so a failed build leaves the running app alone.
    Scripts/xcode.sh debug -quiet build
    ;;
  installed)
    app=/Applications/Speakty.app
    [[ -d "$app" ]] || fail "$app is missing. Install a build with Scripts/install.sh first."
    ;;
  *) fail "Usage: Scripts/run.sh dev | installed" ;;
esac

for id in $installed_id $dev_id; do
  running $id || continue
  osascript -e "tell application id \"$id\" to quit"
  # Quit is immediate; allow a moment for the process to exit.
  for _ in {1..75}; do running $id || break; sleep 0.2; done
  running $id && fail "$id didn't quit within 15 s. Quit it, then retry."
done

# Spotlight skips hidden folders like .build, so Spotlight, Raycast, and System Settings' app pickers
# only list a copy in ~/Applications. Every checkout and worktree updates that one copy. It runs after
# the quit, so it never replaces a running app, and the staged copy keeps a failed ditto from leaving
# a half-written app. Grants follow the signature and bundle ID, so they carry over to the copy.
if [[ -n "${built:-}" ]]; then
  staged="${app:h}/.Speakty Dev.app.new"
  mkdir -p "${app:h}"
  rm -rf "$staged"
  ditto "$built" "$staged"
  rm -rf "$app"
  mv "$staged" "$app"
fi

open "$app"
version=$(/usr/bin/defaults read "$app/Contents/Info" CFBundleShortVersionString)
# Every dev build between releases has the same version, so name the commit it was built from.
if [[ -n "${built:-}" ]]; then
  version+=" @ $(git rev-parse --short HEAD)"
  [[ -z "$(git status --porcelain)" ]] || version+=" with uncommitted changes"
fi
print "Launched $app ($version)"
