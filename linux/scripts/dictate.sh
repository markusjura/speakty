#!/usr/bin/env bash
# Dictates a recording into Speakty Dev's pad and prints what it pasted, without speaking. The
# recording plays into a virtual PipeWire microphone with as many channels as the file, which
# Speakty Dev records from as from any other, so the check covers the whole recording path. Runs on
# a Linux machine in the graphical session, which linux/scripts/remote.sh provides from the Mac.
# Usage: scripts/dictate.sh <recording.wav> [terminal]
#   With `terminal`, the text lands in a kitty window instead, which pastes with Ctrl+Shift+V.
# The check runs on workspace 9 and switches back afterwards. Speakty Dev must run: scripts/run.sh dev.
set -euo pipefail
cd "$(dirname "$0")/.."

recording=$(realpath "${1:?Usage: scripts/dictate.sh <recording.wav> [terminal]}")
settings=~/.config/speakty-dev/settings.json
microphone=speakty-test-microphone
cargo build --quiet --bin speakty-ui
ui=target/debug/speakty-ui
duration=$($ui duration "$recording")
channels=$($ui channels "$recording")
# Channels past two carry no speaker positions, as on interfaces such as the Vocaster.
case $channels in
  1) positions=MONO ;;
  2) positions=FL,FR ;;
  *) positions=$(seq -s, -f 'AUX%g' 0 $((channels - 1))) ;;
esac
output=$(mktemp)
workspace=$($ui workspace)
cleanup() {
  $ui workspace "$workspace"
  jq 'del(.debug.microphone) | if .debug == {} then del(.debug) else . end' "$settings" > "$settings.new" && mv "$settings.new" "$settings"
  pw-cli destroy "$microphone" >/dev/null 2>&1 || true
  rm -f "$output"
}
trap cleanup EXIT

# A duplex node takes playback like a speaker and records like a microphone. Its priority keeps it
# from becoming the default output or input.
pw-cli destroy "$microphone" >/dev/null 2>&1 || true
pw-cli create-node adapter "{ factory.name=support.null-audio-sink node.name=$microphone node.description=\"Speakty test microphone\"
  media.class=Audio/Duplex audio.position=[${positions//,/ }] priority.session=0 priority.driver=0 object.linger=true }" >/dev/null 2>&1
mkdir -p "$(dirname "$settings")"
[[ -f $settings ]] || echo '{}' > "$settings"
jq --arg microphone "$microphone" '.debug.microphone = $microphone' "$settings" > "$settings.new" && mv "$settings.new" "$settings"

$ui workspace 9
wait_for=$(awk -v d="$duration" 'BEGIN { print d + 12 }')
if [[ ${2:-} == terminal ]]; then
  kitty --class kitty -e sh -c "stty raw -echo; timeout --foreground $wait_for cat > $output" >/dev/null 2>&1 &
else
  $ui pad "$wait_for" > "$output" &
fi
sleep 2
# The hold leaves time for the microphone to start, which the log reports, and for the recording's end.
since=$(date +%s)
$ui hold rsuper "$(awk -v d="$duration" 'BEGIN { print d + 4 }')" &
hold=$!
timeout 6 bash -c "until journalctl --user -u speakty-dev.service --since @$since -o cat | grep -q 'Recording at'; do sleep 0.1; done" ||
  { echo "Speakty Dev didn't start recording. Is it running? scripts/run.sh dev" >&2; exit 1; }
pw-play --target "$microphone" --channel-map "$positions" "$recording"
wait $hold
wait
cat "$output"
echo
