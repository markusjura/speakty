#!/bin/zsh
# Runs a Linux script on a Linux machine from the Mac, after copying this checkout's Linux sources,
# uncommitted changes included, to ~/.cache/speakty-remote there. The machine is the SSH host
# `linux`, or $SPEAKTY_LINUX_HOST. The copy is apart from any clone there, which it never touches.
# Usage: linux/scripts/remote.sh <script> [arguments], such as `linux/scripts/remote.sh test.sh`
#        linux/scripts/remote.sh -- '<shell command>', to run a command in the copy's linux/ folder.
# Commands run in the graphical session's environment, so they can reach Wayland and the session bus.
# SPEAKTY_VERSION passes through, for package.sh.
set -euo pipefail
cd "${0:A:h:h:h}"

host=${SPEAKTY_LINUX_HOST:-linux}
[[ $# -ge 1 ]] || { print -u2 "Usage: linux/scripts/remote.sh <script> [arguments] | -- <command>"; exit 1 }
# One copy for every checkout and worktree, as Speakty Dev is on the Mac. target/ stays, so builds are incremental.
copy=.cache/speakty-remote
ssh "$host" mkdir -p "$copy"
rsync -az --delete --exclude target --exclude .DS_Store linux spec "${host}:$copy/"
rsync -az --relative Version.xcconfig macos/Config/Info.plist "${host}:$copy/"
rest=("${@[2,-1]}")
if [[ $1 == -- ]]; then
  command="${(j: :)rest}"
else
  command="scripts/${(q)1} ${(j: :)${(q)rest}}"
fi
# The user manager has the session's WAYLAND_DISPLAY, HYPRLAND_INSTANCE_SIGNATURE, and bus address.
# The copy has no git history, so package.sh names development builds after this commit.
commit=$(git rev-parse --short HEAD)$([[ -z "$(git status --porcelain -- linux spec)" ]] || print .dirty)
tty=(); [[ -t 0 ]] && tty=(-t)
exec ssh $tty "$host" "cd ~/$copy/linux && env \$(systemctl --user show-environment | grep -E '^(WAYLAND_DISPLAY|DISPLAY|XDG_RUNTIME_DIR|DBUS_SESSION_BUS_ADDRESS|HYPRLAND_INSTANCE_SIGNATURE|XDG_CURRENT_DESKTOP)=' | xargs) SPEAKTY_COMMIT=$commit ${SPEAKTY_VERSION:+SPEAKTY_VERSION=$SPEAKTY_VERSION} bash -lc $(printf %q "$command")"
