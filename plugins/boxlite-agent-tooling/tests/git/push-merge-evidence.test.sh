#!/usr/bin/env bash
# Public pre-push regression and bounded receiving-service contract.
set -uo pipefail
test_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
python3 "$test_root/push_merge_evidence.py" "$@"
