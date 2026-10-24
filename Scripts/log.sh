#!/bin/zsh
# Streams the log of whichever Speakty runs: shortcut events, recordings, transcription, pasting, and model downloads.
# Usage: Scripts/log.sh
# The full path matters in zsh, where plain `log` is a builtin.
exec /usr/bin/log stream --level debug --predicate 'subsystem == "local.markus.Speakty"'
