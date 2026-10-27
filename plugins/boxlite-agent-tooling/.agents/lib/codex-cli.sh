#!/usr/bin/env bash
# Executable discovery only; callers select the host through hook_host_kind.
# Source inertly. Call inside the caller's timeout when probing must be bounded.
codex_cli_find() {
  if [[ -n "${CODEX_BIN:-}" ]]; then
    [[ -x "$CODEX_BIN" ]] || return 1
    "$CODEX_BIN" --version >/dev/null 2>&1 || return 1
    printf '%s\n' "$CODEX_BIN"
    return 0
  fi

  local candidate from_path=""
  from_path="$(command -v codex 2>/dev/null || true)"
  for candidate in "$from_path" /Applications/Codex.app/Contents/Resources/codex; do
    [[ -n "$candidate" && -x "$candidate" ]] || continue
    if "$candidate" --version >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}
