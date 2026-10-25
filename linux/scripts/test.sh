#!/usr/bin/env bash
# Runs the unit tests and the shared transcript cases in ../spec.
# Usage: scripts/test.sh [filter], such as `scripts/test.sh hotkey`
set -euo pipefail
cd "$(dirname "$0")/.."
exec cargo test --quiet ${1:+"$1"}
