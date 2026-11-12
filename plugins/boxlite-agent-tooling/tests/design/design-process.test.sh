#!/usr/bin/env bash
set -euo pipefail
directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
python3 "$directory/design-process.test.py"
