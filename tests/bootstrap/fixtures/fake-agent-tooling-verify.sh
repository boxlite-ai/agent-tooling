#!/usr/bin/env bash
set -euo pipefail

[[ "$#" == 1 ]]
[[ -d "$1" ]]
if [[ -e "${FAKE_AGENT_TOOLING_STATE:?}/invalid-install" ]]; then
  printf 'fixture configured hooks do not match recorded revision\n' >&2
  exit 1
fi
