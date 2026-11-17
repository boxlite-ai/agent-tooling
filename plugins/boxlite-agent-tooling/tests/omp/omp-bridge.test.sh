#!/usr/bin/env bash
set -euo pipefail
test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v node >/dev/null || { printf 'omp-bridge tests require Node.js 24\n' >&2; exit 2; }
node --disable-warning=ExperimentalWarning --test "$test_dir/omp-bridge.test.mjs"
