#!/usr/bin/env bash
# Exercise the real shell reader with synthetic Claude/Codex transcripts.
set -euo pipefail
test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
exec python3 "$test_dir/test_snapshot_selection.py"
