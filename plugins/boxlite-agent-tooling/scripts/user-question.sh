#!/usr/bin/env bash
# Render a conversational question through the same utility as managed requests.
set -uo pipefail
if [[ "$#" != 2 ]]; then
  printf 'usage: user-question.sh QUESTION SAFE_FALLBACK\n' >&2
  exit 2
fi
plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)" || exit 2
# shellcheck source=../.agents/lib/user-question.sh
source "$plugin/.agents/lib/user-question.sh" || exit 2
user_question ask "$plugin" "$@"
