#!/usr/bin/env bash
# Records dictations for checks with scripts/dictate.sh, on the machine with the microphone. It shows
# a sentence, records the default microphone with all its channels from one Enter to the next, and
# saves NN.wav with the sentence in NN.txt to ~/.local/share/speakty-dictations, out of this public
# repository. Copy them to the fleet machine from the Mac:
#   scp -3 -r linux:.local/share/speakty-dictations l1:.local/share/
# Usage: scripts/record-dictations.sh [number], to start at a sentence, such as one to redo
set -euo pipefail

sentences=(
  "Let's ship the Linux build of Speakty today and test it on the fleet machine."
  "Codex opened a pull request, and the GitHub Actions run is green."
  "PipeWire records the microphone, and Parakeet turns it into text."
  "Hyprland and Sway both run on Wayland, but GNOME handles overlays differently."
  "Can you check whether kanata still passes the right command key through?"
  "Send the release notes to Markus before the meeting on Thursday."
  "This paragraph is about recording. New paragraph. This one is about pasting into a terminal."
  "The build took three minutes and forty seconds on the Ryzen machine."
  "Ich teste heute die Diktierfunktion auf dem Linux-Rechner."
  "Bitte schick mir die Zusammenfassung vom Meeting bis morgen früh."
  "Speakty läuft jetzt auch unter CachyOS mit Hyprland."
  "Der Fleet-Rechner prüft die Änderungen, während der Gaming-PC ausgeschaltet bleibt."
  "Kannst du den Pull Request reviewen und mir Bescheid geben?"
  "Wir treffen uns am Freitag um halb drei im Büro."
  "Im Codex-Thread hat der Reviewer zwei Findings zu PipeWire gemeldet."
  "Starte Speakty Dev neu und schau dir das Log mit journalctl an."
)
directory=~/.local/share/speakty-dictations
mkdir -p "$directory"
source=$(wpctl inspect @DEFAULT_AUDIO_SOURCE@ | sed -n 's/^.*node\.name = "\(.*\)"$/\1/p')
# The channel count, or else the positions, such as "FL,FR" or "[ AUX0 AUX1 ]", as Speakty counts them.
channels=$(pw-dump | jq --arg name "$source" '[.[] | select(.info.props["node.name"]? == $name)][0].info.props
  | .["audio.channels"] // (.["audio.position"] // "FL,FR" | [scan("[A-Za-z0-9]+")] | length)')
echo "Recording from $source with $channels channels. Speak each sentence as you would dictate it."

for ((i = ${1:-1}; i <= ${#sentences[@]}; i++)); do
  file=$(printf '%s/%02d' "$directory" "$i")
  printf '\n%d of %d: %s\nPress Enter, speak, then press Enter again. ' "$i" "${#sentences[@]}" "${sentences[i - 1]}"
  read -r
  # Without remixing, the recording keeps the microphone's channels as they are. pw-record writes no
  # WAV files with more than two channels, so it records raw samples, which Python wraps.
  pw-record --target "$source" -P '{ stream.dont-remix = true }' --channels "$channels" --rate 48000 --format s16 --raw "$file.raw" 2>/dev/null &
  recording=$!
  read -r
  kill -INT "$recording"
  wait "$recording" || true
  python3 -c 'import sys, wave
with wave.open(sys.argv[1], "wb") as w:
    w.setnchannels(int(sys.argv[2])); w.setsampwidth(2); w.setframerate(48000); w.writeframes(open(sys.argv[3], "rb").read())' "$file.wav" "$channels" "$file.raw"
  rm "$file.raw"
  echo "${sentences[i - 1]}" > "$file.txt"
done
echo "Saved the recordings in $directory."
