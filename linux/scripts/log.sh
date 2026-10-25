#!/usr/bin/env bash
# Streams the log of whichever Speakty runs: shortcut events, recordings, transcriptions, pastes, and updates.
# Usage: scripts/log.sh [journalctl arguments], such as `scripts/log.sh -n 50 --no-pager`
exec journalctl --user -u speakty.service -u speakty-dev.service -o cat -f "$@"
