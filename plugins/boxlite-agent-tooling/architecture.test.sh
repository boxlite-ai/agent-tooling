#!/usr/bin/env bash
# ARCHITECTURE.md is a map, and a map that drifts from the territory misleads worse
# than no map. This pins the parts of it that can be checked mechanically:
#
#   - every script, manifest and spec the map names exists on disk;
#   - every hook script the manifests wire, and every non-test script in
#     .agents/hooks/, is on the map;
#   - the Stop-gate decision table and the rung/outcome pairs its two scripts log are
#     the same set, in both directions;
#   - every state file the map lists is named by some non-test source;
#   - every glossary term is used by some non-test source.
#
# Meanings and line references stay a human's job; only presence is pinned here.
#
# Run with:  bash plugins/boxlite-agent-tooling/architecture.test.sh
# Exits non-zero on any failure.
set -uo pipefail

PLUGIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$PLUGIN/../.." && pwd)"
DOC="$PLUGIN/ARCHITECTURE.md"
# stop-gate.sh logs the summary rungs around the verdict check it runs.
STOP_GATE_SCRIPTS=("$PLUGIN/.agents/hooks/stop-gate.sh" "$PLUGIN/.agents/hooks/preflight-verdict-check.sh")
CLAUDE_HOOKS="$PLUGIN/hooks/hooks.json"
CODEX_HOOKS="$PLUGIN/hooks/codex-hooks.json"

pass=0
fail=0
# Increment pass counter and print a PASS line.  # $1 = test name
ok()  { pass=$((pass + 1)); printf '  PASS  %s\n' "$1"; }
# Increment fail counter and print a FAIL line.  # $1 = test name
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }

command -v jq >/dev/null 2>&1 || { printf 'jq is required to run these tests\n' >&2; exit 2; }
[[ -r "$DOC" ]] || { printf 'missing %s\n' "$DOC" >&2; exit 2; }

# The territory: every non-test source a term or state file could live in. The parity
# suite is included by name because the host doctrine is written there and nowhere else.
SOURCES="$(find "$PLUGIN/.agents/hooks" "$PLUGIN/.agents/lib" "$PLUGIN/.agents/watch" \
  "$PLUGIN/.githooks" "$PLUGIN/scripts" "$PLUGIN/.claude/agents" "$REPO_ROOT/templates" \
  -type f ! -name '*.test.sh' 2>/dev/null; printf '%s\n' "$PLUGIN/host-parity.test.sh")"

# Print the body of one "## <name>" section of the map.  # $1 = heading text
section() { awk -v h="## $1" '$0 == h {on = 1; next} /^## / {on = 0} on' "$DOC"; }

# Case-insensitive fixed-string or regex search over every source file.  # $1 = -F|-E, $2 = needle
# One path per line, read whole: xargs or an unquoted expansion would split a checkout
# path that contains a space.
in_sources() {
  local mode="$1" needle="$2" file
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    grep -qi "$mode" -- "$needle" "$file" 2>/dev/null && return 0
  done <<<"$SOURCES"
  return 1
}

echo "== every path the map names exists =="
# shellcheck disable=SC2016 # the backticks are literal: they delimit code spans in the map
for rel in $(grep -oE '`(\.agents/(hooks|lib|watch|prompts)/[A-Za-z0-9_.-]+|\.githooks/[A-Za-z0-9_-]+|scripts/[A-Za-z0-9_.-]+|\.claude/agents/[A-Za-z0-9_.-]+|hooks/[A-Za-z0-9_.-]+\.json|guidance/[A-Za-z0-9_.-]+|templates/[A-Za-z0-9_.-]+|[a-z-]+\.test\.sh)`' "$DOC" | tr -d '`' | sort -u); do
  case "$rel" in
    templates/*) abs="$REPO_ROOT/$rel" ;;
    *)           abs="$PLUGIN/$rel" ;;
  esac
  if [[ -e "$abs" ]]; then ok "exists: $rel"; else bad "named on the map but missing: $rel"; fi
done

echo "== every wired or shipped hook script is on the map =="
wired="$(jq -r '.hooks | to_entries[] | .value[] | .hooks[]? | .command // empty' "$CLAUDE_HOOKS" "$CODEX_HOOKS" \
  | grep -oE '\.agents/hooks/[A-Za-z0-9_.-]+' | sort -u)"
shipped="$(cd "$PLUGIN" && find .agents/hooks -maxdepth 1 -name '*.sh' ! -name '*.test.sh' | sort -u)"
for script in $(printf '%s\n%s\n' "$wired" "$shipped" | sort -u); do
  if grep -qF "\`$script\`" "$DOC"; then ok "on the map: $script"; else bad "not on the map: $script"; fi
done

echo "== the decision table and the gate log the same rung/outcome pairs =="
table_pairs="$(section 'Stop gate decisions' \
  | awk -F'|' 'NF >= 4 { r = $2; o = $3; gsub(/[` ]/, "", r); gsub(/[` ]/, "", o);
                if (r != "" && r != "Rung" && r !~ /^-+$/) print r " " o }' | sort -u)"
gate_pairs="$(grep -ohE 'log_decision [a-z]+ [A-Za-z_-]+' "${STOP_GATE_SCRIPTS[@]}" | sed 's/^log_decision //' | sort -u)"
if [[ -z "$table_pairs" ]]; then bad "decision table has no rows"; fi
for pair in $(comm -23 <(printf '%s\n' "$table_pairs") <(printf '%s\n' "$gate_pairs") | tr ' ' '/'); do
  bad "table row the gate never logs: ${pair}"
done
for pair in $(comm -13 <(printf '%s\n' "$table_pairs") <(printf '%s\n' "$gate_pairs") | tr ' ' '/'); do
  bad "gate decision missing from the table: ${pair}"
done
if [[ -n "$table_pairs" && "$table_pairs" == "$gate_pairs" ]]; then
  ok "decision table matches the gate ($(printf '%s\n' "$gate_pairs" | wc -l | tr -d ' ') pairs)"
fi

echo "== every state file the map lists is named by a source =="
# shellcheck disable=SC2016 # literal backticks again, see above
for name in $(section 'State files' | grep -oE '^- `[^`]+`' | tr -d '`' | sed 's/^- //'); do
  if in_sources -F "$name"; then ok "state file in source: $name"; else bad "state file not in any source: $name"; fi
done

echo "== every glossary term is used by a source =="
# A here-string keeps the loop in this shell, so the counters update; a pipe into
# `while read` would run it in a subshell and lose them.
glossary_terms="$(section 'Glossary' | grep -oE '^- \*\*[^*]+\*\*' | sed -E 's/^- \*\*//; s/\*\*$//')"
while IFS= read -r term; do
  [[ -n "$term" ]] || continue
  # "session scope" may be spelled session_scope or session-scope in code.
  pattern="$(printf '%s' "$term" | sed 's/[.]/\\./g; s/ /[ _-]/g')"
  if in_sources -E "$pattern"; then ok "glossary term in source: $term"; else bad "glossary term not used by any source: $term"; fi
done <<<"$glossary_terms"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
