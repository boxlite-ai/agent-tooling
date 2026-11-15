#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Stop-hook continuation toward the next workflow stage.
#
# stdin: the host's Stop payload. stdout: one {decision:"block",reason} object when
# either holds, otherwise nothing:
#   - the design gate blocked an edit this session for a reason the agent can resolve,
#     and the branch still has no passed, advised design (once per recorded block);
#   - the branch has a passed, advised design and pending work in a state not yet
#     reminded about (once per work state).
#
# Exit 0 in both cases. Exit 2 only when a dependency or library is missing. The
# step reads local state only, and its own read or write failures never continue or
# block a turn.
#
# Tests: bash tests/scripts/continue-workflow.test.sh
set -uo pipefail
plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
for dependency in git jq perl; do
  command -v "$dependency" >/dev/null 2>&1 || {
    printf 'continue-workflow: required command missing: %s\n' "$dependency" >&2; exit 2;
  }
done
# shellcheck source=../.agents/lib/verdict-audit-state.sh
source "$plugin/.agents/lib/verdict-audit-state.sh" || exit 2
# shellcheck source=../.agents/lib/subagent.sh
source "$plugin/.agents/lib/subagent.sh" || exit 2

payload="$(cat)"
repo="$(git -C "${CLAUDE_PROJECT_DIR:-$PWD}" rev-parse --show-toplevel 2>/dev/null)" || exit 0
repo="$(cd "$repo" && pwd -P)" || exit 0
scope="$(verdict_audit_scope_from_hook_payload "$payload" "$repo" 2>/dev/null)" || exit 0
git_dir="$(git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null)" || exit 0
branch="$(git -C "$repo" symbolic-ref --quiet --short HEAD 2>/dev/null)" || exit 0

# ── Passed design: the local records hold a PASS and advice for the same content ──
design_record() { # file name -> JSON body
  local snapshot
  snapshot="$(verdict_audit_read_json_snapshot "$git_dir/$1" 2>/dev/null)" || return 1
  printf '%s' "${snapshot#*$'\n'}"
}
design_passed() {
  local audit advice
  audit="$(design_record agent-tooling-design-audit.json)" || return 1
  advice="$(design_record agent-tooling-design-advice.json)" || return 1
  jq -en --arg root "$repo" --arg branch "$branch" --argjson audit "$audit" --argjson advice "$advice" '
    ($audit | type) == "object" and ($advice | type) == "object"
    and $audit.root == $root and $audit.branch == $branch and $audit.verdict == "PASS"
    and $advice.root == $root and $advice.branch == $branch
    and ($audit.content_sha256 | type) == "string"
    and $advice.content_sha256 == $audit.content_sha256' >/dev/null 2>&1
}
continue_turn() {  # reason
  jq -nc --arg reason "$1" '{decision:"block",reason:$reason}'
  exit 0
}

# ── A design-gate block this session: continue once toward an audited design ──────
# preflight-design-doc.sh records blocks the agent can resolve alone; each record is
# consumed here, so a later Stop without a new block ends the turn.
block_record="$repo/.agents/state/design-gate-block-$scope.json"
if [[ -e "$block_record" || -L "$block_record" ]]; then
  block="$(verdict_audit_read_json_snapshot "$block_record" 2>/dev/null)" || block=""
  rm -f -- "$block_record" 2>/dev/null || exit 0
  if [[ "$(jq -r '.branch // ""' <<<"${block#*$'\n'}" 2>/dev/null)" == "$branch" ]] && ! design_passed; then
    reason="$(subagent_prompt reminders/design-continue "$plugin" "branch=$branch" 2>/dev/null)" || exit 0
    continue_turn "$reason"
  fi
fi
design_passed || exit 0

# ── Pending work ──────────────────────────────────────────────────────────────────
head="$(git -C "$repo" rev-parse HEAD 2>/dev/null)" || exit 0
# Lock-free reads: a Stop runs beside other sessions' Git commands in this worktree.
status="$(git -C "$repo" --no-optional-locks status --porcelain 2>/dev/null)" || exit 0
# Staging moves a path between status columns and turns an untracked file into an
# added one without changing the work, so the state hashes paths only and leaves
# added files out of the content difference.
paths="$(cut -c4- <<<"$status")"
content="$(git -C "$repo" --no-optional-locks diff HEAD --diff-filter=a 2>/dev/null \
  | git -C "$repo" hash-object --stdin 2>/dev/null)" || exit 0
# Without an upstream branch, commits ahead of the default branch count as not pushed.
base="$(git -C "$repo" rev-parse --verify --quiet '@{upstream}' 2>/dev/null)" \
  || base="$(git -C "$repo" rev-parse --verify --quiet refs/remotes/origin/HEAD 2>/dev/null)" \
  || base=""
unpushed=0
if [[ -n "$base" ]]; then
  unpushed="$(git -C "$repo" rev-list --count "$base..HEAD" 2>/dev/null)" || exit 0
fi
pending=""
[[ -z "$status" ]] || pending="uncommitted changes"
if (( unpushed > 0 )); then
  pending="${pending:+$pending and }$unpushed unpushed commit(s)"
fi
[[ -n "$pending" ]] || exit 0

# ── Once per work state ───────────────────────────────────────────────────────────
state="$(printf '%s\n%s\n%s\n%s\n' "$head" "$unpushed" "$content" "$paths" \
  | git -C "$repo" hash-object --stdin 2>/dev/null)" || exit 0
record="$repo/.agents/state/workflow-reminder-$scope.json"
if previous="$(verdict_audit_read_json_snapshot "$record" 2>/dev/null)"; then
  [[ "$(jq -r '.state // ""' <<<"${previous#*$'\n'}" 2>/dev/null)" != "$state" ]] || exit 0
fi
reason="$(subagent_prompt reminders/workflow-continue "$plugin" \
  "branch=$branch" "pending=$pending" 2>/dev/null)" || exit 0
# The record is written before the reminder: a failed write must not repeat a reminder.
mkdir -p "$repo/.agents/state" 2>/dev/null || exit 0
jq -nc --arg state "$state" '{state:$state}' | verdict_audit_write_atomic "$record" 2>/dev/null || exit 0
continue_turn "$reason"
