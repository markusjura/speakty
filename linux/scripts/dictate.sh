#!/usr/bin/env bash
# Dictates a recording into Speakty Dev's pad and prints what it pasted, without speaking. Runs on the
# Linux machine in the graphical session, which linux/scripts/remote.sh provides from the Mac.
# Usage: scripts/dictate.sh <recording.wav> [terminal]
#   With `terminal`, the text lands in a kitty window instead, which pastes with Ctrl+Shift+V.
# The check runs on workspace 9 and switches back afterwards, and it stops Voxtype meanwhile, which
# reacts to the same key. Speakty Dev must run: scripts/run.sh dev.
set -euo pipefail
cd "$(dirname "$0")/.."

recording=$(realpath "${1:?Usage: scripts/dictate.sh <recording.wav> [terminal]}")
settings=~/.config/speakty-dev/settings.json
cargo build --quiet --bin speakty-ui
seconds=$(awk -v d="$(target/debug/speakty-ui duration "$recording")" 'BEGIN { print d + 1.5 }')
output=$(mktemp)
voxtype=$(systemctl --user is-active voxtype.service 2>/dev/null || true)
workspace=$(hyprctl activeworkspace -j | jq .id)
cleanup() {
  hyprctl dispatch "hl.dsp.focus({ workspace = $workspace })" >/dev/null
  [[ $voxtype == active ]] && systemctl --user start voxtype.service
  rm -f "$output"
}
trap cleanup EXIT
[[ $voxtype == active ]] && systemctl --user stop voxtype.service

mkdir -p "$(dirname "$settings")"
[[ -f $settings ]] || echo '{}' > "$settings"
jq --arg file "$recording" '.debug.testAudioFile = $file' "$settings" > "$settings.new" && mv "$settings.new" "$settings"
hyprctl dispatch "hl.dsp.focus({ workspace = 9 })" >/dev/null
wait_for=$(awk -v s="$seconds" 'BEGIN { print s + 6 }')
if [[ ${2:-} == terminal ]]; then
  kitty --class kitty -e sh -c "stty raw -echo; timeout --foreground $wait_for cat > $output" >/dev/null 2>&1 &
else
  target/debug/speakty-ui pad "$wait_for" > "$output" &
fi
sleep 2
target/debug/speakty-ui hold rsuper "$seconds"
wait
cat "$output"
echo
