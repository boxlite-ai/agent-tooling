#!/usr/bin/env bash
# PostToolUse hook (design #563): after a successful `git push`, file one GitHub issue per
# unfiled ledger entry on the pushed branch, at most three per push. Filing is advisory:
# every failure keeps the entry local and is reported as context; the exit is always 0.
# Opt out with AUDIT_LEDGER_FILING=0.
#
# Tests: bash tests/audit/ledger-filing.test.sh
# shellcheck source-path=SCRIPTDIR
set -uo pipefail

[[ "${AUDIT_LEDGER_FILING:-1}" == 0 ]] && exit 0
for dependency in jq git gh perl; do command -v "$dependency" >/dev/null 2>&1 || exit 0; done
tooling_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
lib_dir="$tooling_root/.agents/lib"
for library in hook-host verdict-audit-state audit-ledger; do
  # shellcheck source=/dev/null
  source "$lib_dir/$library.sh" || exit 0
done

payload="$(head -c 1048577)"
command="$(jq -r '.tool_input.command // .tool_input.cmd // ""' <<<"$payload" 2>/dev/null)" || exit 0
hook_command_segment_verb "$command" 'git[[:space:]]+(push)' >/dev/null || exit 0
# Same success test as the PR watch hook: a nonzero exit or Git's failure text means no push.
jq -e '(.tool_response | type) == "object" and (.tool_response | has("exit_code"))
  and .tool_response.exit_code != 0' <<<"$payload" >/dev/null 2>&1 && exit 0
response="$(jq -r 'if (.tool_response | type) == "string" then .tool_response
  else ((.tool_response.stdout // .tool_response.output // "") + "\n" + (.tool_response.stderr // "")) end' \
  <<<"$payload" 2>/dev/null)"
[[ "$response" =~ (^|[[:space:]])(fatal|error):|\[(remote\ )?rejected\]|Everything\ up-to-date ]] && exit 0

workdir="$(hook_payload_workdir "$payload" "${CLAUDE_PROJECT_DIR:-$PWD}")" || exit 0
repo="$(git -C "$workdir" rev-parse --show-toplevel 2>/dev/null)" || exit 0
branch="$(git -C "$repo" branch --show-current 2>/dev/null)"
[[ -n "$branch" ]] || exit 0
entries="$(audit_ledger_unfiled_entries "$repo" "$branch")" || exit 0
[[ -n "$entries" ]] || exit 0

notes=()
note() { notes+=("ledger: $1"); }
emit() {
  (( ${#notes[@]} )) || exit 0
  jq -nc --arg c "$(printf '%s\n' "${notes[@]}")" \
    '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$c}}'
  exit 0
}
origin="$(git -C "$repo" remote get-url origin 2>/dev/null)"
if [[ "$origin" =~ ^(https://github\.com/|git@github\.com:|ssh://git@github\.com/)([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)$ ]]; then
  slug="${BASH_REMATCH[2]%.git}"
else
  note "unresolved findings stay local: origin is not a github.com repository"; emit
fi
tip="$(git -C "$repo" rev-parse --verify -q "refs/remotes/origin/$branch^{commit}")" \
  || { note "unresolved findings stay local: origin/$branch is unknown after the push"; emit; }

bounded_gh() { perl -e 'alarm 10; exec @ARGV' gh "$@"; }
scratch="$(mktemp -d "${TMPDIR:-/tmp}/ledger-file.XXXXXX")" || exit 0
trap 'rm -rf "$scratch"' EXIT
# Only entries that reach GitHub use the budget: three per push, started within 30 s, so
# a 10 s search plus a 20 s create still ends inside the manifests' 60 s timeout.
count=0
while IFS= read -r entry && (( count < 3 && SECONDS < 30 )); do
  gate="$(jq -r .gate <<<"$entry")" attempt="$(jq -r .attempt_id <<<"$entry")"
  where="$gate@$(jq -r '.head[0:7]' <<<"$entry")"
  title="Unresolved audit findings: $where on $branch (${attempt:0:8})"
  # Link every path:line anchor that exists in the pushed commit.
  anchors=""
  while IFS= read -r anchor; do
    path="${anchor%:*}" line="${anchor##*:}"
    git -C "$repo" cat-file -e "$tip:$path" 2>/dev/null || continue
    anchors+="| [\`$anchor\`](https://github.com/$slug/blob/$tip/$path#L$line) | \`${tip:0:7}\` |"$'\n'
  done < <(jq -r '.findings[] | .evidence, .behavior | strings' <<<"$entry" \
    | grep -oE '[A-Za-z0-9_][A-Za-z0-9_./-]*:[0-9]+' | sort -u)
  if [[ -z "$anchors" ]]; then
    note "$where stays local: no finding cites a path in the pushed commit"; continue
  fi
  body="$(jq -r --arg branch "$branch" --arg where "$where" --arg anchors "$anchors" '
    "## TL;DR\n\nA stuck \(.gate) audit loop on `\($branch)` proceeded with \(.findings | length) open finding(s).\n\n"
    + "## Details\n\nThe gate recorded them in its ledger as `\($where)`, class `\(.class)`.\n\n"
    + "| Anchor | Pushed commit |\n| --- | --- |\n\($anchors)\n"
    + ([.findings[] | "### \(.id) (\(.severity))\n\n```text\nBehavior: \(.behavior)\nCriterion: \(.criterion)\nEvidence: \(.evidence)\n```\n"]
       | join("\n"))
    + "\n<!-- boxlite-ledger:\(.gate):\(.attempt_id) -->\n"' <<<"$entry")" || continue
  # The shared scan in gh-write.sh misses emails and temporary paths; refuse them here.
  if perl -0777 -ne 'exit(/[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+\.[A-Za-z0-9.-]+|\/(?:tmp|private|var\/folders)\//i ? 0 : 1)' <<<"$body"; then
    note "$where stays local: a finding names an email address or a temporary path"; continue
  fi
  count=$((count + 1))
  if url="$(bounded_gh issue list --repo "$slug" --state all --search "\"$title\" in:title" \
      --json title,url --jq "map(select(.title == \"${title//\"/}\")) | .[0].url // empty" 2>/dev/null)" \
      && [[ -n "$url" ]]; then
    audit_ledger_mark_filed "$repo" "$branch" "$gate" "$attempt" "$url" || true
    note "$where was already filed: $url"; continue
  fi
  printf '%s\n' "$body" > "$scratch/body.md"
  if url="$(perl -e 'alarm 20; exec @ARGV' bash "$tooling_root/scripts/gh-write.sh" issue create \
      --body-file "$scratch/body.md" --repo "$slug" --title "$title" 2>"$scratch/error")" \
      && [[ "$url" =~ ^https://github\.com/[^[:space:]]+/issues/[0-9]+$ ]]; then
    audit_ledger_mark_filed "$repo" "$branch" "$gate" "$attempt" "$url" \
      || note "filed $url but could not record it; a later push will find it by title"
    note "filed $url for $where"
  else
    note "$where stays local: filing failed ($(head -c 200 "$scratch/error" | tr '\n' ' '))"
  fi
done <<<"$entries"
emit
