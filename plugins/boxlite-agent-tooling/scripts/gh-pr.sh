#!/usr/bin/env bash
set -euo pipefail
plugin_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
exec bash "$plugin_root/.agents/hooks/preflight-pr-review.sh" --publish-body-file "$@"
