#!/bin/zsh
# Measures dictation models on the eval set and prints a table to compare them.
# Usage:
#   Scripts/benchmark.sh <model>...  # parakeet-ultra, nemotron-unified; BenchmarkModel lists them
#   Scripts/benchmark.sh seed        # adds the starter set to the eval folder
# The eval folder is ~/Library/Application Support/Speakty/eval: <language>-<name>.wav with what was
# said in <language>-<name>.txt, and vocabulary.txt with one term per line. The README describes it.
# BenchmarkTests runs each model in an optimized unit test host as a dictation runs. A running
# Speakty Dev quits for the run, as for Scripts/test.sh, and is relaunched afterwards. Each clip's
# transcript lands in .build/benchmark.
set -euo pipefail
cd "${0:A:h:h}"

eval_dir="$HOME/Library/Application Support/Speakty/eval"
output=.build/benchmark

# The starter set: 25 German and 25 English FLEURS clips with their cased, punctuated transcripts,
# from FluidAudio's mirror, and ten sentences in macOS voices with vocabulary terms, two of them with
# words a term must not replace. Needs ffmpeg. Clips already in the folder are kept.
seed() {
  mkdir -p "$eval_dir"
  local fleurs=https://huggingface.co/datasets/FluidInference/fleurs/resolve/main
  json=$(mktemp)
  trap 'rm -f "$json" "$json.wav"' EXIT
  for language in de_de en_us; do
    curl -fsSL "$fleurs/$language/$language.json" -o "$json"
    for i in {0..24}; do
      local id=$(plutil -extract samples.$i.id raw -o - "$json")
      local name="$eval_dir/${language%%_*}-fleurs-${id##*_}"
      [[ -e "$name.wav" ]] && continue
      plutil -extract samples.$i.raw_transcription raw -o - "$json" > "$name.txt"
      curl -fsSL "$fleurs/$language/$id.wav" -o "$json.wav"
      # Many FLEURS clips peak below -40 dB, which Speakty takes for silence, so they're brought to
      # the level of a dictation: peaks at -3 dB.
      local peak=$(ffmpeg -nostats -i "$json.wav" -af volumedetect -f null - 2>&1 | awk '/max_volume/ { print $5 }')
      ffmpeg -loglevel error -i "$json.wav" -af "volume=$(( -3 - peak ))dB" "$name.wav"
    done
  done

  [[ -e "$eval_dir/vocabulary.txt" ]] || print -l CLAUDE.md Expo FluidAudio "GitHub Actions" GNOME grill-with-docs \
    Hyprland PipeWire Speakty TanStack > "$eval_dir/vocabulary.txt"
  # name, voice, what Speakty should write, and what the voice says when that differs.
  local clips=(
    en-vocab-01 Samantha "I switched my desktop from GNOME to Hyprland last week." ""
    en-vocab-02 Samantha "PipeWire handles the audio, so restart it when the microphone goes quiet." ""
    en-vocab-03 Samantha "We fetch the data with TanStack Query and render it in Expo." ""
    en-vocab-04 Samantha "Push the value onto the stack, then expose the port." ""
    en-vocab-05 Samantha "Add the rule to CLAUDE.md and run the GitHub Actions workflow again." \
      "Add the rule to Claude dot M D and run the GitHub Actions workflow again."
    de-vocab-01 Anna "Ich habe Hyprland gestern auf dem Laptop installiert." ""
    de-vocab-02 Anna "Speakty nutzt FluidAudio, um das Modell auf der Neural Engine auszuführen." ""
    de-vocab-03 Anna "Der Skill grill-with-docs fragt so lange nach, bis der Plan steht." \
      "Der Skill grill with docs fragt so lange nach, bis der Plan steht."
    de-vocab-04 Anna "Leg den Wert auf den Stack und starte den Server neu." ""
    de-vocab-05 Anna "Die GitHub Actions laufen erst wieder, wenn PipeWire das Mikrofon findet." ""
  )
  for name voice text spoken in "${clips[@]}"; do
    [[ -e "$eval_dir/$name.wav" ]] && continue
    print -r -- "$text" > "$eval_dir/$name.txt"
    say -v $voice -o "$eval_dir/$name.wav" --data-format=LEI16@16000 "${spoken:-$text}"
  done
  print "The eval set in $eval_dir has $(ls "$eval_dir"/*.wav | wc -l | tr -d ' ') clips."
}

[[ $# -gt 0 ]] || { print -u2 "Usage: Scripts/benchmark.sh <model>... | seed"; exit 1 }
if [[ "$1" == seed ]]; then seed; exit 0; fi

rm -rf $output
mkdir -p $output
dev_running=$(lsappinfo find bundleid=local.markus.Speakty.dev)
result=0
# xcodebuild passes TEST_RUNNER_ variables to the test host without the prefix. A model's first run
# downloads it, which takes a few minutes.
TEST_RUNNER_SPEAKTY_BENCHMARK_MODELS="$*" TEST_RUNNER_SPEAKTY_BENCHMARK_EVAL="$eval_dir" \
  TEST_RUNNER_SPEAKTY_BENCHMARK_OUTPUT="$PWD/$output" \
  Scripts/xcode.sh benchmark test -only-testing:SpeaktyTests/BenchmarkTests/testBenchmark >$output/test.log 2>&1 || result=$?
[[ -n "$dev_running" ]] && open ~/Applications/"Speakty Dev.app"
(( result == 0 )) || {
  grep -E "error|failed" $output/test.log >&2; print -u2 "The benchmark failed; $output/test.log has the details."; exit 1
}
cat $output/report.md
print "Each clip's transcript is in $PWD/$output."
