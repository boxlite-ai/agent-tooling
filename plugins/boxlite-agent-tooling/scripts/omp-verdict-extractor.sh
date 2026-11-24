#!/usr/bin/env bash
# Turn-text extractor for OMP (oh-my-pi) session files, read by the verdict
# check through VERDICT_EXTRACTOR_CMD: "$1" is the transcript path, stdout is
# the last assistant reply's text (possibly empty; no trailing newline).
set -euo pipefail

if (( $# != 1 )) || [[ ! -r "$1" ]]; then
  printf 'omp-verdict-extractor: expected one readable session file, got: %s\n' "${*:-<none>}" >&2
  exit 2
fi

# OMP session entries: {"type":"message","message":{"role":"assistant",
# "content":[{"type":"text","text":...}, ...]}}. The final assistant entry can
# be thinking-only (aborted settle), so take the last one carrying text.
# Slurping is bounded by the verdict check's own input limits, not here.
jq -rs '
  [ .[]
    | select(.type == "message" and .message.role == "assistant")
    | [ .message.content[]? | select(.type == "text") | .text ]
    | select(length > 0)
    | join("\n")
  ][-1] // ""
' "$1" | printf '%s' "$(cat)"
