#!/usr/bin/env bash
# Follows the log of whichever Speakty runs: shortcut events, recordings, transcriptions, pastes, and updates.
# Usage: scripts/log.sh [journalctl arguments], such as `scripts/log.sh -n 50 --no-pager` to print the end instead
[[ $# -gt 0 ]] || set -- -f
exec journalctl --user -u speakty.service -u speakty-dev.service -o cat "$@"
