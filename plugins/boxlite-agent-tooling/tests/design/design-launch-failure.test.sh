#!/usr/bin/env bash
set -uo pipefail
python3 "$(dirname "${BASH_SOURCE[0]}")/design-launch-failure.test.py"
