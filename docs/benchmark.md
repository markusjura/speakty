# Benchmarking dictation models

`macos/Scripts/benchmark.sh` compares local dictation models on recordings with known transcripts, the way Speakty uses them.

```sh
macos/Scripts/benchmark.sh seed                             # once: add the starter set
macos/Scripts/benchmark.sh parakeet-ultra nemotron-unified
```

## What it measures

Each clip goes through the dictation path on a warm model, in an optimized build: silence trimming, the model, vocabulary boosting, then vocabulary spelling and the closing period.

- WER: word error rate overall and per language. Both texts are normalized first, as in FluidAudio's multilingual benchmarks: digits spelled out, lowercased, punctuation and symbols removed.
- Cased and Punctuated: WER with capitalization kept, and with `. , ? ! : ;` scored as words. Speakty pastes both, so they count.
- Vocabulary: how many vocabulary terms in the references the transcripts got right, and how many terms they wrote where none was said.
- Time-to-text: median time from the end of the audio to the final text.

Each clip's transcript is in `macos/.build/benchmark`.

## The eval set

It lives in `~/Library/Application Support/Speakty/eval`, outside the repository.

- `<language>-<name>.wav` is 16 kHz mono speech. `<language>-<name>.txt` holds what was said, cased and punctuated as Speakty should write it. The prefix, such as `de` or `en`, is the language.
- `vocabulary.txt` has one term per line, like the vocabulary in Settings > Transcript.

`seed` adds 25 German and 25 English clips from the FLEURS test set, plus ten clips with vocabulary terms in macOS voices. That's enough for a first look, but read speech and synthetic voices aren't dictation. Base a model decision on your own dictations.

To add one, record what you'd dictate, for example with QuickTime Player's New Audio Recording. Convert it with `ffmpeg -i Recording.m4a -ar 16000 -ac 1 en-mine-01.wav`, then write what you said into `en-mine-01.txt`. Speakty doesn't keep its recordings.

## Adding a model

Add a case to `BenchmarkModel` in `macos/SpeaktyTests/BenchmarkTests.swift` that loads the model and returns a `Recognizer`.
