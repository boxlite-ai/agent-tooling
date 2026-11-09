#!/usr/bin/env bash
# Reads one auditor's model and effort for one host from .agents/auditor-models.tsv
# (design #474). Source only; defining functions has no other effect.
#
# auditor_model_load <tooling-root> <auditor> <claude|codex>
#   Sets auditor_model and auditor_effort. The literal `unset` means "send no flag".
#   A missing table or row, an empty or malformed cell, or a duplicate row prints the
#   reason to stderr and returns 2, so no route silently falls back to a CLI default.
auditor_model_load() {
  local table="$1/.agents/auditor-models.tsv" line name host model effort extra
  local found=false
  auditor_model="" auditor_effort=""
  if [[ ! -r "$table" ]]; then
    printf 'auditor-model: cannot read %s\n' "$table" >&2
    return 2
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"  # A CRLF checkout must parse like an LF one.
    [[ -z "$line" || "$line" == \#* ]] && continue
    IFS=$'\t' read -r name host model effort extra <<<"$line"
    [[ "$name" == "$2" && "$host" == "$3" ]] || continue
    if [[ "$found" == true || -n "$extra" \
          || ! "$model" =~ ^[A-Za-z0-9][A-Za-z0-9._:/@-]*$ \
          || ! "$effort" =~ ^(unset|low|medium|high|xhigh|max)$ ]]; then
      printf 'auditor-model: malformed or duplicate row for %s on %s in %s\n' "$2" "$3" "$table" >&2
      return 2
    fi
    found=true
    auditor_model="$model"
    auditor_effort="$effort"
  done < "$table"
  if [[ "$found" != true ]]; then
    printf 'auditor-model: no row for %s on %s in %s\n' "$2" "$3" "$table" >&2
    return 2
  fi
}

# Claude Code CLI flags for the loaded row; `unset` cells add none.
auditor_model_claude_args() {
  auditor_model_args=()
  [[ "$auditor_model" == unset ]] || auditor_model_args+=(--model "$auditor_model")
  [[ "$auditor_effort" == unset ]] || auditor_model_args+=(--effort "$auditor_effort")
}

# Codex CLI overrides for the loaded row; the cell grammar keeps the TOML strings safe.
auditor_model_codex_args() {
  auditor_model_args=()
  [[ "$auditor_model" == unset ]] || auditor_model_args+=(-c "model=\"$auditor_model\"")
  [[ "$auditor_effort" == unset ]] \
    || auditor_model_args+=(-c "model_reasoning_effort=\"$auditor_effort\"")
}
