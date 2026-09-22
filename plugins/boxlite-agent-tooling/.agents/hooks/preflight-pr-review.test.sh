#!/usr/bin/env bash
# Tests for .agents/hooks/preflight-pr-review.sh
#
# Covers:
#   1. Command matcher: gh pr create / edit / ready vs. unrelated bash,
#      chained invocations, draft exclusion.
#   2. Gate logic: missing / mismatched / stale / malformed-message /
#      consumed marker paths.
#
# Supported shell boundary: direct simple commands, the literal command/exec/env
# wrappers, and literal eval or bash/sh -c payloads are inspectable. Compound or
# repeated execution, dynamic executable structure, and mutable body-file chains
# are rejected conservatively; this suite does not claim to implement Bash.
#
# Run with:  bash .agents/hooks/preflight-pr-review.test.sh
# Exits non-zero on any failure.
set -uo pipefail

# Resolve from THIS script's location, not the caller's cwd. `git rev-parse
# --show-toplevel` returns whichever checkout the shell sits in, so running this
# suite from another worktree silently tests THAT checkout's copy instead of the
# one shipped beside these tests, and a two-side check reports a false pass.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$REPO_ROOT/.agents/hooks/preflight-pr-review.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export CLAUDE_PROJECT_DIR="$TMP"
mkdir -p "$TMP/.agents/state"

# The hook resolves its repo from the AMBIENT cwd, while the marker below is
# keyed to REPO_ROOT's branch and HEAD. Invoked from anywhere else the two
# disagree, every marker looks stale, and the suite reports 42/12 instead of
# 54/0 — green-looking from here, wrong from there. Pin cwd so they match.
cd "$REPO_ROOT" || exit 1
BRANCH="$(git -C "$REPO_ROOT" branch --show-current)"
HEAD_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD)"

pass=0
fail=0

run() {
  local desc="$1" cmd="$2" expect="$3" out decision
  out=$(jq -nc --arg command "$cmd" '{tool_input:{command:$command}}' | "$HOOK")
  if [[ -z "$out" ]]; then
    decision="passthrough"
  else
    decision=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null || echo "parse_error")
  fi
  if [[ "$decision" == "$expect" ]]; then
    pass=$((pass + 1))
    printf '  PASS  %s\n' "$desc"
  else
    fail=$((fail + 1))
    printf '  FAIL  %s  (got=%s expected=%s)\n' "$desc" "$decision" "$expect"
    printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' >&2
  fi
}

write_marker() {
  local message="$1" spec request_id
  rm -f "$TMP/.agents/state/pr-review-request.json"
  spec="$(jq -nc --arg repo "$(git rev-parse --show-toplevel)" --arg branch "$BRANCH" --arg head "$HEAD_SHA" \
    '{binding:{repo:$repo,branch:$branch,head:$head,session:""},prefix:"reviewed:",fallback:"keep-draft",minimum_words:1}')"
  request_id="$(bash "$REPO_ROOT/scripts/timed-user-prompt.sh" request \
    "$TMP/.agents/state/pr-review-request.json" "$spec" | jq -r .id)"
  jq -nc --arg b "$BRANCH" --arg h "$HEAD_SHA" --arg m "$message" --arg r "$request_id" \
        '{branch:$b, head:$h, message:$m,request:$r}' \
        > "$TMP/.agents/state/pr-reviewed.json"
}

reason_for() {
  jq -nc --arg command "$1" '{tool_input:{command:$command}}' | "$HOOK" \
    | jq -r '.hookSpecificOutput.permissionDecisionReason // ""'
}

reason_for_repo() { # repo, project state root, command
  local repo="$1" state_root="$2" cmd="$3"
  jq -nc --arg command "$cmd" '{tool_input:{command:$command}}' \
    | (cd "$repo" && CLAUDE_PROJECT_DIR="$state_root" "$HOOK") \
    | jq -r '.hookSpecificOutput.permissionDecisionReason // ""'
}

assert_reason_budget() {
  local desc="$1" reason="$2" bytes
  bytes="$(LC_ALL=C printf '%s' "$reason" | wc -c | tr -d ' ')"
  if (( bytes <= 1200 )); then
    pass=$((pass + 1)); printf '  PASS  %s (%s bytes)\n' "$desc" "$bytes"
  else
    fail=$((fail + 1)); printf '  FAIL  %s (%s bytes; max 1200)\n' "$desc" "$bytes"
  fi
}

assert_reason_contains() {
  local desc="$1" reason="$2" needle="$3"
  case "$reason" in
    *"$needle"*) pass=$((pass + 1)); printf '  PASS  %s\n' "$desc" ;;
    *) fail=$((fail + 1)); printf '  FAIL  %s (missing: %s)\n' "$desc" "$needle" ;;
  esac
}

echo "## Matcher: should pass through (not a gated gh pr invocation)"
rm -f "$TMP/.agents/state/pr-reviewed.json"
run "ls"                                "ls"                                "passthrough"
run "gh pr list (different subcmd)"     "gh pr list"                        "passthrough"
run "gh pr view (different subcmd)"     "gh pr view 123"                    "passthrough"
run "gh issue create (different verb)"  "gh issue create -t foo -b Short"            "passthrough"
run "gh issue operands named pr and ready" \
  "gh issue create --title pr --body ready"                                 "passthrough"
run "echo literal mention"              "echo 'gh pr create'"               "passthrough"
run "unrelated echo expansion"          'echo $HOME'                        "passthrough"
run "unrelated pathname expansion"      'ls *.md'                           "passthrough"
run "unrelated git pathname expansion"  'git add plugins/*'                 "passthrough"
run "gh issue dynamic label"            'gh issue list --label $LABEL'      "passthrough"
run "nohup benign expansion"            'nohup echo $HOME'                  "passthrough"
run "env benign expansion"              'env echo $HOME'                    "passthrough"
run "nohup benign pathname expansion"   'nohup ls *.md'                     "passthrough"
run "sudo gh issue dynamic label"       'sudo gh issue list --label $LABEL' "passthrough"
run "git push (other hook's domain)"    "git push origin main"              "passthrough"
run "heredoc body mentions trigger"     $'git commit -m "$(cat <<\'EOF\'\nbody mentions `gh pr create`\nEOF\n)"' "passthrough"
run "quoted heredoc substitution stays literal" \
  $'cat <<\'EOF\'\n$(gh pr ready 42)\nEOF'                              "passthrough"
run "backslash-quoted heredoc substitution stays literal" \
  $'cat <<\\EOF\n$(gh pr ready 42)\nEOF'                              "passthrough"
run "multiline w/ backtick trigger"     $'git commit -m "fix bug"\n# `gh pr create`' "passthrough"

echo
echo "## Matcher: draft exclusion (only on create)"
run "gh pr create --draft"              "gh pr create --draft -t wip -b Short"       "passthrough"
run "gh pr create -d short flag"        "gh pr create -d -t wip -b Short"            "passthrough"
run "draft may carry an explicit body"  "gh pr create --draft --body prose" "passthrough"
run "draft body may start with a dash"   "gh pr create --draft --body -draft" "passthrough"
run "draft may use --dry-run"           "gh pr create --draft --body Short --dry-run"    "passthrough"
run "noncanonical late draft stays gated" "gh pr create -t wip --draft"     "deny"
run "label value --draft is not a draft flag" "gh pr create --label --draft" "deny"
run "short label value -d is not a draft flag" "gh pr create -l -d"          "deny"
run "later --draft=false cancels draft exemption" \
  "gh pr create --draft --draft=false --title \"feat(api): graph\" --body prose" "deny"
run "clustered -d=false cancels draft exemption" \
  "gh pr create --draft -fd=false --title \"not conventional\" --body prose" "deny"
run "dynamic word cannot inject a draft=false override" \
  'gh pr create --draft "${DRAFT_OVERRIDE:---draft=false}" --title "not conventional" --body prose' "deny"
run "pathname expansion cannot inject a draft=false override" \
  'gh pr create --draft --label ?* --title "not conventional" --body prose' "deny"
run "command substitution cannot inject a draft=false override" \
  'gh pr create --draft "$(printf -- --draft=false)" --title "not conventional" --body prose' "deny"
run "compound all-draft source remains execution-ambiguous" \
  'gh pr create --draft && true' "deny"
run "gh pr create --draft=true"         "gh pr create --draft=true -t wip -b Short"  "passthrough"
run "gh pr create -d=true"              "gh pr create -d=true -t wip -b Short"       "passthrough"
run "-- stops draft option parsing"     "gh pr create -- --draft"           "deny"
run "-d inside a title is not a draft flag" \
  'gh pr create --title "feat(cli): document the -d option"'               "deny"
run "draft create cannot exempt a later ready command" \
  "gh pr create --draft && gh pr ready 42"                                 "deny"
run "draft create cannot exempt a later non-draft create" \
  'gh pr create --draft; gh pr create --title "not conventional"'          "deny"

echo
echo "## Matcher: should gate"
run "gh pr create direct"               "gh pr create -t foo"               "deny"
run "gh pr edit direct"                 "gh pr edit 42 --body foo"          "deny"
run "gh pr ready direct"                "gh pr ready 42"                    "deny"
run "repo override between noun and create" \
  "gh pr --repo other-owner/other-repo create --title oops --body prose"     "deny"
run "repo override between noun and edit" \
  "gh pr -Rother-owner/other-repo edit 42 --body prose"                     "deny"
run "repo override between noun and ready" \
  "gh pr --repo other-owner/other-repo ready 42"                            "deny"
run "chained with &&"                   "cd x && gh pr create -t foo"       "deny"
run "chained with ;"                    "echo done; gh pr create -t foo"    "deny"
run "command substitution"              "out=\$(gh pr create -t foo)"       "deny"
run "double-quoted command substitution" 'echo "$(gh pr ready 42)"'          "deny"
run "double-quoted backtick substitution" 'echo "```gh pr ready 42```"'       "deny"
run "unquoted heredoc command substitution" \
  $'cat <<EOF\n$(gh pr ready 42)\nEOF'                                  "deny"
run "line-continuation does not quote heredoc delimiter" \
  $'cat <<\\\nEOF\n$(gh pr ready 42)\nEOF'                               "deny"
run "unquoted heredoc backtick substitution" \
  $'cat <<EOF\n`gh pr ready 42`\nEOF'                                  "deny"
run "escaped substitution stays literal" 'echo "\$(gh pr ready 42)"'         "passthrough"
run "escaped backticks stay literal"      'echo "\`\`\`gh pr ready 42\`\`\`"' "passthrough"
run "command wrapper"                    "command gh pr ready 42"            "deny"
run "absolute gh executable path"         "/opt/homebrew/bin/gh pr ready 42"  "deny"
run "relative gh executable path"         "./tools/gh pr ready 42"            "deny"
run "command-wrapped gh executable path"  "command /opt/bin/gh pr ready 42"   "deny"
run "exec wrapper"                       "exec gh pr ready 42"               "deny"
run "env wrapper"                        "env gh pr ready 42"                "deny"
run "redirection before protected command" "> $TMP/pr.out gh pr create --title oops --body prose" "deny"
run "redirection between gh and pr"       "gh >$TMP/pr.out pr ready 42"      "deny"
run "redirection between pr and ready"    "gh pr >$TMP/pr.out ready 42"      "deny"
run "redirection between gh and pr create" \
  "gh >$TMP/pr.out pr create --title oops --body prose"                     "deny"
run "redirection between pr and create" \
  "gh pr >$TMP/pr.out create --title oops --body prose"                     "deny"
run "fd duplication between gh and pr"  "gh 2>&1 pr ready 42"              "deny"
run "fd duplication between pr and ready" "gh pr 2>&1 ready 42"            "deny"
run "fd duplication between pr and create" \
  "gh pr 2>&1 create --title oops --body prose"                             "deny"
run "combined output redirection between gh and pr" \
  "gh &>$TMP/pr.out pr ready 42"                                            "deny"
run "noclobber redirection between gh and pr" \
  "gh >|$TMP/pr.out pr ready 42"                                            "deny"
run "noclobber redirection between pr and ready" \
  "gh pr >|$TMP/pr.out ready 42"                                            "deny"
run "process-substitution redirection between gh and pr" \
  "gh < <(printf x) pr ready 42"                                            "deny"
run "process-substitution redirection between pr and ready" \
  "gh pr > >(cat) ready 42"                                                 "deny"
run "globbed protected executable"       "$TMP/fake-bin/g[h] pr create --title oops --body prose" "deny"
run "one executable glob can expand to gh and pr" "[gp][hr] ready 42"       "deny"
run "unquoted executable expansion can supply gh and pr" '$CMD ready 42'     "deny"
run "unquoted executable expansion can supply whole prefix" \
  '$WHOLE --title oops --body prose'                                         "deny"
run "launcher executable expansion can supply gh and pr" \
  'nohup $CMD ready 42'                                                       "deny"
run "nohup launcher"                     "nohup gh pr create --title oops --body prose" "deny"
run "absolute env launcher"              "/usr/bin/env gh pr create --title oops --body prose" "deny"
run "coproc launcher"                    "coproc gh pr create --title oops --body prose" "deny"
run "sudo launcher"                      "sudo gh pr create --title oops --body prose" "deny"
run "nice launcher"                      "nice gh pr create --title oops --body prose" "deny"
run "timeout launcher"                   "timeout 30 gh pr create --title oops --body prose" "deny"
run "launcher with globbed repository option" \
  "nohup gh --re[p]o other-owner/other-repo pr ready 42"                    "deny"
run "launcher with dynamic repository option" \
  'sudo gh "$OPT" other-owner/other-repo pr ready 42'                       "deny"
run "literal bash -c payload"             "bash -c 'gh pr ready 42'"           "deny"
run "literal bash combined -lc payload"   "bash -lc 'gh pr ready 42'"          "deny"
run "literal sh combined -lc payload"     "sh -lc 'gh pr ready 42'"            "deny"
run "literal eval payload"                "eval 'gh pr ready 42'"              "deny"
run "literal heredoc executed by bash" \
  $'bash <<\'EOF\'\ngh pr ready 42\nEOF'                              "deny"
run "expanding heredoc executed by bash" \
  $'bash <<EOF\ngh pr ready 42\nEOF'                                  "deny"
run "dynamic bash -c payload"             'bash -c "$PR_SCRIPT"'               "deny"
run "dynamic eval payload"                'eval "$PR_SCRIPT"'                  "deny"
run "exec combined flags wrapper"         "exec -cl gh pr ready 42"            "deny"
run "builtin eval wrapper"                "builtin eval 'gh pr ready 42'"       "deny"
run "builtin exec wrapper"                "builtin exec gh pr ready 42"         "deny"
run "literal assignments assemble protected argv" \
  'cmd=gh; noun=pr; verb=ready; "$cmd" "$noun" "$verb" 42'                    "deny"
run "literal alias payload"               "alias ship='gh pr ready 42'; ship"   "deny"
run "literal alias may compose a protected prefix" \
  $'bash -O expand_aliases -c \'alias ship="gh pr"\nship ready 42\''                  "deny"
run "control-flow prefix"                "if true; then gh pr ready 42; fi"   "deny"
run "time reserved-word prefix"           "time -p gh pr ready 42"             "deny"
run "gh global --repo option"            "gh --repo boxlite-ai/tooling pr ready 42" "deny"
run "dynamic executable word"            '$(printf gh) pr ready 42'            "deny"
run "dynamic executable path"            '"/opt/$GH_DIR/gh" pr ready 42'       "deny"
run "dynamic pr noun"                    'gh $(printf pr) ready 42'            "deny"
run "dynamic protected subcommand"        'gh pr $(printf ready) 42'            "deny"
run "ANSI-C executable word"              "\$'gh' pr ready 42"                 "deny"
run "ANSI-C pr noun"                      "gh \$'pr' ready 42"                 "deny"
run "ANSI-C protected subcommand"          "gh pr \$'ready' 42"                 "deny"
run "env var prefix"                    "FOO=bar gh pr create -t foo"       "deny"
# Newline-before-verb: multi-line Bash with the gh invocation on line 2. Before the
# newline-as-separator fix this SILENTLY PASSED THROUGH (the bypass); must deny now.
run "newline before pr create"          $'cd x\ngh pr create -t foo'         "deny"
run "escaped newline cannot split gh spelling" \
  $'g\\\nh pr ready 42'                                                       "deny"
run "quoted chain text is not a command segment" \
  'echo "documentation: && gh pr ready 42"'                                "passthrough"
run "gh-suffixed executable lookalike"     "/opt/bin/gh-helper pr ready 42"    "passthrough"
run "gh path with trailing component"      "/opt/bin/gh/tool pr ready 42"      "passthrough"

echo
echo "## Gate logic: marker file states"

run_hard_deny() { # description command
  local desc="$1" cmd="$2" out decision marker_state
  write_marker "reviewed: hard deny must preserve this marker"
  out="$(printf '%s' "$cmd" | jq -Rs '{tool_input:{command:.}}' | "$HOOK")"
  decision="$(printf '%s' "$out" \
    | jq -r '.hookSpecificOutput.permissionDecision // "passthrough"' 2>/dev/null \
    || echo parse_error)"
  [[ -f "$TMP/.agents/state/pr-reviewed.json" ]] \
    && marker_state=kept || marker_state=gone
  if [[ "$decision" == deny && "$marker_state" == kept ]]; then
    pass=$((pass + 1)); printf '  PASS  %s\n' "$desc"
  else
    fail=$((fail + 1)); printf '  FAIL  %s (decision=%s marker=%s)\n' \
      "$desc" "$decision" "$marker_state"
  fi
}

run_allow_consumes() { # description command
  local desc="$1" cmd="$2" out decision marker_state
  write_marker "reviewed: one literal wrapped operation"
  out="$(printf '%s' "$cmd" | jq -Rs '{tool_input:{command:.}}' | "$HOOK")"
  [[ -z "$out" ]] && decision=passthrough || decision=deny
  [[ -f "$TMP/.agents/state/pr-reviewed.json" ]] \
    && marker_state=kept || marker_state=gone
  if [[ "$decision" == passthrough && "$marker_state" == gone ]]; then
    pass=$((pass + 1)); printf '  PASS  %s\n' "$desc"
  else
    fail=$((fail + 1)); printf '  FAIL  %s (decision=%s marker=%s)\n' \
      "$desc" "$decision" "$marker_state"
  fi
}

run_hard_deny "loop body cannot spend one marker repeatedly" \
  'for item in one two; do gh pr ready 42; done'
run_hard_deny "conditional branch cannot spend an execution-ambiguous marker" \
  'if true; then gh pr ready 42; fi'
run_hard_deny "repeated function calls cannot reuse one lexical protected site" \
  'open_pr() { gh pr ready 42; }; open_pr; open_pr'
run_hard_deny "dynamic bash payload cannot spend a marker" \
  'bash -c "$PR_SCRIPT"'
run_hard_deny "dynamic eval payload cannot spend a marker" \
  'eval "$PR_SCRIPT"'
run_hard_deny "bash combined flags cannot spend a marker" \
  "bash -lc 'gh pr ready 42'"
run_hard_deny "sh combined flags cannot spend a marker" \
  "sh -lc 'gh pr ready 42'"
run_hard_deny "exec combined flags cannot spend a marker" \
  'exec -cl gh pr ready 42'
run_hard_deny "builtin eval cannot spend a marker" \
  "builtin eval 'gh pr ready 42'"
run_hard_deny "builtin exec cannot spend a marker" \
  'builtin exec gh pr ready 42'
run_hard_deny "literal assignments cannot assemble and spend a marker" \
  'cmd=gh; noun=pr; verb=ready; "$cmd" "$noun" "$verb" 42'
run_hard_deny "dynamic gh executable path cannot spend a marker" \
  '"/opt/$GH_DIR/gh" pr ready 42'
run_hard_deny "ANSI-C executable structure cannot spend a marker" \
  "\$'gh' pr ready 42"
run_hard_deny "literal alias expansion cannot spend a marker" \
  "alias ship='gh pr ready 42'; ship"
run_hard_deny "command -p cannot change executable lookup" \
  'command -p gh pr ready 42'
run_allow_consumes "direct exec wrapper spends exactly one marker" \
  'exec gh pr ready 42'
run_allow_consumes "direct env wrapper spends exactly one marker" \
  'env gh pr ready 42'
run_allow_consumes "absolute gh path spends exactly one marker" \
  '/opt/homebrew/bin/gh pr ready 42'
run_allow_consumes "command-wrapped gh path spends exactly one marker" \
  'command ./tools/gh pr ready 42'

write_marker "reviewed: refactor auth middleware"
run "valid marker → allow"              "gh pr ready 42"                    "passthrough"
run "marker consumed on allow"          "gh pr ready 42"                    "deny"

write_marker "reviewed: exactly one protected operation"
multi_pr_out="$(printf '%s' 'gh pr ready 41 && gh pr ready 42' \
  | jq -Rs '{tool_input:{command:.}}' | "$HOOK")"
multi_pr_decision="$(printf '%s' "$multi_pr_out" \
  | jq -r '.hookSpecificOutput.permissionDecision // "passthrough"' 2>/dev/null \
  || echo parse_error)"
if [[ "$multi_pr_decision" == deny \
   && -f "$TMP/.agents/state/pr-reviewed.json" ]]; then
  pass=$((pass + 1)); printf '  PASS  multiple protected operations deny atomically without consuming one marker\n'
else
  fail=$((fail + 1)); printf '  FAIL  multiple protected operations deny atomically without consuming one marker (decision=%s marker=%s)\n' \
    "$multi_pr_decision" "$([[ -f "$TMP/.agents/state/pr-reviewed.json" ]] && echo kept || echo gone)"
fi
run "preserved marker authorizes one retried operation" \
  "gh pr ready 42" "passthrough"

# Both hooks select the same inode before either reaches the consume step. Stable
# selection is not authorization: exactly one atomic consume may spend the marker.
write_marker "reviewed: concurrent marker"
CONCURRENT_PR_BARRIER="$TMP/concurrent-pr-barrier"
CONCURRENT_PR_DATE="$TMP/concurrent-pr-date"
mkdir -p "$CONCURRENT_PR_BARRIER" "$CONCURRENT_PR_DATE"
CONCURRENT_PR_REAL_DATE="$(command -v date)"
# shellcheck disable=SC2016 # These literals are the mock date executable's source.
printf '%s\n' '#!/usr/bin/env bash' \
  '[[ "${1:-}" != -u ]] || exec "$TEST_REAL_DATE" "$@"' \
  ': > "$TEST_BARRIER/$$"' \
  'deadline=$((SECONDS + 5))' \
  'while (( $(find "$TEST_BARRIER" -type f | wc -l) < 2 )); do' \
  '  (( SECONDS < deadline )) || exit 124' \
  'done' \
  'exec "$TEST_REAL_DATE" "$@"' > "$CONCURRENT_PR_DATE/date"
chmod +x "$CONCURRENT_PR_DATE/date"
concurrent_pr_pids=()
for concurrent_pr_index in 1 2; do
  (printf '%s' 'gh pr ready 42' | jq -Rs '{tool_input:{command:.}}' \
    | PATH="$CONCURRENT_PR_DATE:$PATH" \
        TEST_BARRIER="$CONCURRENT_PR_BARRIER" \
        TEST_REAL_DATE="$CONCURRENT_PR_REAL_DATE" "$HOOK" \
        > "$TMP/concurrent-pr-$concurrent_pr_index.out") &
  concurrent_pr_pids+=("$!")
done
concurrent_pr_wait_status=0
for concurrent_pr_pid in "${concurrent_pr_pids[@]}"; do
  wait "$concurrent_pr_pid" || concurrent_pr_wait_status=$?
done
concurrent_pr_allows=0
concurrent_pr_denies=0
for concurrent_pr_index in 1 2; do
  concurrent_pr_out="$(<"$TMP/concurrent-pr-$concurrent_pr_index.out")"
  if [[ -z "$concurrent_pr_out" ]]; then
    concurrent_pr_allows=$((concurrent_pr_allows + 1))
  elif [[ "$(printf '%s' "$concurrent_pr_out" \
      | jq -r '.hookSpecificOutput.permissionDecision // ""' 2>/dev/null)" == deny ]]; then
    concurrent_pr_denies=$((concurrent_pr_denies + 1))
  fi
done
if [[ "$concurrent_pr_wait_status" -eq 0 \
   && "$concurrent_pr_allows" -eq 1 && "$concurrent_pr_denies" -eq 1 ]]; then
  pass=$((pass + 1)); printf '  PASS  one PR acknowledgment authorizes exactly one concurrent command\n'
else
  fail=$((fail + 1)); printf '  FAIL  one PR acknowledgment authorizes exactly one concurrent command (allows=%s denies=%s wait=%s)\n' \
    "$concurrent_pr_allows" "$concurrent_pr_denies" "$concurrent_pr_wait_status"
fi

# Compose the two races above: both hooks select the old marker, then a newer marker
# replaces the canonical path before either consume. A replacement is not proof that
# either selector spent the old one, so it must never let both commands through.
write_marker "reviewed: concurrent selected marker"
jq '.message="reviewed: concurrent replacement marker"' "$TMP/.agents/state/pr-reviewed.json" \
  > "$TMP/concurrent-replacement-pr-reviewed.json"
CONCURRENT_REPLACEMENT_BARRIER="$TMP/concurrent-replacement-pr-barrier"
CONCURRENT_REPLACEMENT_DATE="$TMP/concurrent-replacement-pr-date"
CONCURRENT_REPLACEMENT_LEADER="$TMP/concurrent-replacement-pr-leader"
mkdir -p "$CONCURRENT_REPLACEMENT_BARRIER" "$CONCURRENT_REPLACEMENT_DATE"
# shellcheck disable=SC2016 # These literals are the mock date executable's source.
printf '%s\n' '#!/usr/bin/env bash' \
  '[[ "${1:-}" != -u ]] || exec "$TEST_REAL_DATE" "$@"' \
  ': > "$TEST_BARRIER/$$"' \
  'deadline=$((SECONDS + 5))' \
  'while (( $(find "$TEST_BARRIER" -type f | wc -l) < 2 )); do' \
  '  (( SECONDS < deadline )) || exit 124' \
  'done' \
  'if mkdir "$TEST_LEADER" 2>/dev/null; then' \
  '  mv "$TEST_REPLACEMENT" "$TEST_MARKER"' \
  'else' \
  '  sleep 1' \
  'fi' \
  'exec "$TEST_REAL_DATE" "$@"' > "$CONCURRENT_REPLACEMENT_DATE/date"
chmod +x "$CONCURRENT_REPLACEMENT_DATE/date"
concurrent_replacement_pids=()
for concurrent_replacement_index in 1 2; do
  (printf '%s' 'gh pr ready 42' | jq -Rs '{tool_input:{command:.}}' \
    | PATH="$CONCURRENT_REPLACEMENT_DATE:$PATH" \
        TEST_BARRIER="$CONCURRENT_REPLACEMENT_BARRIER" \
        TEST_LEADER="$CONCURRENT_REPLACEMENT_LEADER" \
        TEST_REPLACEMENT="$TMP/concurrent-replacement-pr-reviewed.json" \
        TEST_MARKER="$TMP/.agents/state/pr-reviewed.json" \
        TEST_REAL_DATE="$CONCURRENT_PR_REAL_DATE" "$HOOK" \
        > "$TMP/concurrent-replacement-pr-$concurrent_replacement_index.out") &
  concurrent_replacement_pids+=("$!")
done
concurrent_replacement_wait_status=0
for concurrent_replacement_pid in "${concurrent_replacement_pids[@]}"; do
  wait "$concurrent_replacement_pid" || concurrent_replacement_wait_status=$?
done
concurrent_replacement_allows=0
concurrent_replacement_denies=0
for concurrent_replacement_index in 1 2; do
  concurrent_replacement_out="$(<"$TMP/concurrent-replacement-pr-$concurrent_replacement_index.out")"
  if [[ -z "$concurrent_replacement_out" ]]; then
    concurrent_replacement_allows=$((concurrent_replacement_allows + 1))
  elif [[ "$(printf '%s' "$concurrent_replacement_out" \
      | jq -r '.hookSpecificOutput.permissionDecision // ""' 2>/dev/null)" == deny ]]; then
    concurrent_replacement_denies=$((concurrent_replacement_denies + 1))
  fi
done
concurrent_replacement_message="$(jq -r '.message // "missing"' \
  "$TMP/.agents/state/pr-reviewed.json" 2>/dev/null || echo missing)"
if [[ "$concurrent_replacement_wait_status" -eq 0 \
   && "$concurrent_replacement_allows" -le 1 \
   && "$concurrent_replacement_denies" -ge 1 \
   && "$concurrent_replacement_message" == "reviewed: concurrent replacement marker" ]]; then
  pass=$((pass + 1)); printf '  PASS  concurrent replacement cannot double-spend one PR acknowledgment\n'
else
  fail=$((fail + 1)); printf '  FAIL  concurrent replacement cannot double-spend one PR acknowledgment (allows=%s denies=%s wait=%s marker=%s)\n' \
    "$concurrent_replacement_allows" "$concurrent_replacement_denies" \
    "$concurrent_replacement_wait_status" "$concurrent_replacement_message"
fi
rm -rf "$CONCURRENT_REPLACEMENT_LEADER"
rm -f "$TMP/.agents/state/pr-reviewed.json" "$TMP/concurrent-replacement-pr-reviewed.json"

write_marker "reviewed: interactive edit is unchecked"
run "edit without explicit flags stays denied" "gh pr edit 42"               "deny"

write_marker "reviewed: metadata-only edit"
run "explicit metadata-only edit → allow" "gh pr edit 42 --add-label ready" "passthrough"

write_marker "yes"
run "malformed message → deny"          "gh pr ready 42"                    "deny"

write_marker ""
run "empty message → deny"              "gh pr ready 42"                    "deny"

write_marker "reviewed: stale"
jq --arg h "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" '.head=$h' \
   "$TMP/.agents/state/pr-reviewed.json" > "$TMP/.agents/state/x.json" \
   && mv "$TMP/.agents/state/x.json" "$TMP/.agents/state/pr-reviewed.json"
run "HEAD mismatch → deny"              "gh pr ready 42"                    "deny"

write_marker "reviewed: branch test"
jq --arg b "some-other-branch" '.branch=$b' \
   "$TMP/.agents/state/pr-reviewed.json" > "$TMP/.agents/state/x.json" \
   && mv "$TMP/.agents/state/x.json" "$TMP/.agents/state/pr-reviewed.json"
run "branch mismatch → deny"            "gh pr ready 42"                    "deny"

write_marker "reviewed: old"
touch -t 202001010000 "$TMP/.agents/state/pr-reviewed.json"
run "stale mtime (>max_age) → deny"     "gh pr ready 42"                    "deny"

echo
echo "## PR state paths are bounded stable regular files"

# A valid marker reached through a symlink is still attacker-selected state. The hook
# must reject it instead of following the link and consuming the pathname.
write_marker "reviewed: symlink marker"
mv "$TMP/.agents/state/pr-reviewed.json" "$TMP/outside-pr-reviewed.json"
ln -s "$TMP/outside-pr-reviewed.json" "$TMP/.agents/state/pr-reviewed.json"
run "symlink acknowledgment marker → deny" "gh pr ready 42" "deny"
rm -f "$TMP/.agents/state/pr-reviewed.json" "$TMP/outside-pr-reviewed.json"

# FIFOs are readable according to `test -r`, but opening one without a writer blocks.
# Exercise the real hook under an alarm so the failure is an observable result, not a
# suite hang.
mkfifo "$TMP/.agents/state/pr-reviewed.json"
fifo_marker_out="$(printf '%s' 'gh pr ready 42' | jq -Rs '{tool_input:{command:.}}' \
  | perl -e '$SIG{ALRM}=sub{exit 124}; alarm 2; exec @ARGV' "$HOOK" 2>/dev/null)"
fifo_marker_rc=$?
fifo_marker_decision="$(printf '%s' "$fifo_marker_out" \
  | jq -r '.hookSpecificOutput.permissionDecision // "parse_error"' 2>/dev/null \
  || echo parse_error)"
if [[ "$fifo_marker_rc" == 0 && "$fifo_marker_decision" == deny ]]; then
  pass=$((pass + 1)); printf '  PASS  FIFO acknowledgment marker fails closed without blocking\n'
else
  fail=$((fail + 1)); printf '  FAIL  FIFO acknowledgment marker fails closed without blocking (rc=%s decision=%s)\n' \
    "$fifo_marker_rc" "$fifo_marker_decision"
fi
rm -f "$TMP/.agents/state/pr-reviewed.json"

# Replace the canonical marker after its content/freshness was selected but before the
# allow path consumes it. The newer marker must survive, and the old selection must not
# authorize because the gate could not atomically spend it at the canonical name.
write_marker "reviewed: selected marker"
jq '.message="reviewed: replacement marker"' "$TMP/.agents/state/pr-reviewed.json" \
  > "$TMP/replacement-pr-reviewed.json"
DATE_WRAP="$TMP/date-wrap"
mkdir -p "$DATE_WRAP"
REAL_DATE="$(command -v date)"
printf '%s\n' '#!/usr/bin/env bash' \
  'if [[ "${1:-}" == "+%s" && -e "$TEST_REPLACEMENT" ]]; then' \
  '  mv "$TEST_REPLACEMENT" "$TEST_MARKER"' \
  'fi' \
  'exec "$TEST_REAL_DATE" "$@"' > "$DATE_WRAP/date"
chmod +x "$DATE_WRAP/date"
replacement_out="$(printf '%s' 'gh pr ready 42' | jq -Rs '{tool_input:{command:.}}' \
  | PATH="$DATE_WRAP:$PATH" TEST_REAL_DATE="$REAL_DATE" \
      TEST_REPLACEMENT="$TMP/replacement-pr-reviewed.json" \
      TEST_MARKER="$TMP/.agents/state/pr-reviewed.json" "$HOOK")"
if [[ -z "$replacement_out" ]]; then
  replacement_decision=passthrough
else
  replacement_decision="$(printf '%s' "$replacement_out" \
    | jq -r '.hookSpecificOutput.permissionDecision // "parse_error"' 2>/dev/null \
    || echo parse_error)"
fi
replacement_message="$(jq -r '.message // "missing"' \
  "$TMP/.agents/state/pr-reviewed.json" 2>/dev/null || echo missing)"
if [[ "$replacement_decision" == deny \
   && "$replacement_message" == "reviewed: replacement marker" ]]; then
  pass=$((pass + 1)); printf '  PASS  marker replacement survives and forces a safe retry\n'
else
  fail=$((fail + 1)); printf '  FAIL  marker replacement survives and forces a safe retry (decision=%s marker=%s)\n' \
    "$replacement_decision" "$replacement_message"
fi
rm -f "$TMP/.agents/state/pr-reviewed.json" "$TMP/replacement-pr-reviewed.json"

echo
echo "## Title check: every supplied title spelling must be a Conventional-Commit subject <=72"
TITLE_GRAPH=$'## Call graph\n\n```text\nBefore\n  old_path (Gate · src/gate.sh:10)\n\nAfter\n  new_path (Gate · src/gate.sh:20)\n```'
run_title() {
  write_marker "reviewed: title case"
  run "$@"
}
run_title "bad --title (no type prefix) → deny"  "gh pr create --title \"add a cool thing\" --body '$TITLE_GRAPH'"  "deny"
run_title "over-72 --title → deny"               "gh pr create --title \"feat(api): this title is far too long and clearly exceeds the seventy-two character ceiling\" --body '$TITLE_GRAPH'"  "deny"
run_title "short fix title accepts a concise description" \
  "gh pr create -t \"fix(api): repair graph\" --body '$TITLE_GRAPH'" "passthrough"
run_title "attached short fix title accepts a concise description" \
  "gh pr create -t\"fix(api): repair graph\" --body '$TITLE_GRAPH'" "passthrough"
run_title "escaped unquoted fix title accepts a concise description" \
  "gh pr create --title fix:\\ graph --body '$TITLE_GRAPH'" "passthrough"
run_title "unquoted title glob cannot replace the inspected title" \
  "gh pr create --title 'feat: '* --body '$TITLE_GRAPH'" "deny"
run_title "dynamic short title fails closed" \
  "gh pr create -t \"\$PR_TITLE\" --body '$TITLE_GRAPH'" "deny"
run_title "mixed fill/title cluster fails closed" \
  "gh pr create -ft=\"fix(api): repair graph\" --body '$TITLE_GRAPH'" "deny"
run_title "dynamic mixed fill/title cluster fails closed" \
  "gh pr create -ft \"\$PR_TITLE\" --body '$TITLE_GRAPH'" "deny"
run_title "title value named --draft is not a draft flag" \
  "gh pr create --title \"--draft\" --body '$TITLE_GRAPH'" "deny"
run_title "metadata before title is outside canonical create prefix" \
  "gh pr create --base main --title \"feat(api): graph\" --body '$TITLE_GRAPH'" "deny"
write_marker "reviewed: long title case"
run "good --title + valid marker → allow"  "gh pr create --title \"feat(api): add a cool thing\" --body '$TITLE_GRAPH'"  "passthrough"
run "marker consumed after allow → deny"   "gh pr create --title \"feat(api): add a cool thing\" --body '$TITLE_GRAPH'"  "deny"
write_marker "reviewed: short title case"
run "good short title + valid marker → allow" \
  "gh pr create -t \"feat(api): add a cool thing\" --body '$TITLE_GRAPH'" "passthrough"
write_marker "reviewed: equals title case"
run "good -t= title + valid marker → allow" \
  "gh pr create -t=\"feat(api): add a cool thing\" --body '$TITLE_GRAPH'" "passthrough"

# Flags belonging to an earlier simple command or protected segment must not be
# reused as evidence for a later malformed create. These cases carry a valid
# marker so only segment-local title/body parsing can make them deny.
GRAPH_DECOY=$'## Call graph\n\n```text\nBefore\n  old_path (Gate · src/gate.sh:10)\n\nAfter\n  new_path (Gate · src/gate.sh:20)\n```'
printf '%s\n' "$GRAPH_DECOY" > "$TMP/decoy-body.md"
write_marker "reviewed: reject unprotected decoys"
run "earlier unprotected flags cannot validate a later malformed create" \
  "echo --title \"feat(api): decoy\" -F $TMP/decoy-body.md && gh pr create --title \"not conventional\" --body \"prose\"" \
  "deny"
write_marker "reviewed: reject chained decoys"
run "earlier protected flags cannot validate a later malformed create" \
  "gh pr edit 7 --title \"feat(api): decoy\" -F $TMP/decoy-body.md && gh pr create --title \"not conventional\" --body \"prose\"" \
  "deny"

echo
echo "## Body check: concise descriptions may use any explanatory form"

GRAPH=$'```text\npush PR -> select matrix -> run tests\n```'
GRAPH_CRLF="${GRAPH//$'\n'/$'\r\n'}"
FIX_GRAPH=$'Await the console bind before attaching.\n\nFixes #1042'
GRAPH_WITH_TRAILING_SECTION="$GRAPH"$'\n\nChecks: workflow suite passed.'
BULLET_BODY=$'- Routine SDK CI: 21 jobs -> 11.\n- Full compatibility matrix still runs weekly.\n- Workflow tests passed.'
EXAMPLE_BODY=$'Example: change only the Python image -> build Python, skip Node.\nVerified with the image-selection test.'
SEQUENCE_BODY=$'```mermaid\nsequenceDiagram\n  Contributor->>CI: Push SDK change\n  CI->>Runner: Run focused matrix\n```'
TABLE_BODY=$'| Trigger | Matrix |\n| --- | --- |\n| PR | Focused |\n| Weekly | Full |'
# Include a formerly valid graph so the old gate reaches the oversized body,
# rather than denying for the unrelated lack of a graph.
LEGACY_GRAPH=$'## Call graph\n\n```text\nBefore\n  old_path (Gate · src/gate.sh:10)\nAfter\n  new_path (Gate · src/gate.sh:20)\n```'
LONG_BODY="$LEGACY_GRAPH"$'\n'"$(awk 'BEGIN {for (i=0; i<201; i++) printf "word "}')"
LONG_UNSPACED_BODY="$LEGACY_GRAPH"$'\n'"$(awk 'BEGIN {for (i=0; i<2001; i++) printf "字"}')"
LIMIT_WORDS_BODY="$(printf 'x %.0s' {1..60})"$'\n\n'"$(printf 'x %.0s' {1..60})"
LIMIT_CHARS_BODY="$(awk 'BEGIN {for (i=0; i<80; i++) printf "字"}')"
OVER_WORDS_BODY="$LIMIT_WORDS_BODY x"
OVER_CHARS_BODY="${LIMIT_CHARS_BODY}字"
EMOJI_BODY="$(awk 'BEGIN {for (i=0; i<2000; i++) printf "😀"}')"
HUGE_BODY="$(awk 'BEGIN {for (i=0; i<8001; i++) printf "x"}')"
# Read the example rather than duplicating its text in the test.
CONTRIB_BODY="$(awk '/^````markdown$/ {inside=1; next} inside && /^````$/ {exit} inside {print}' "$REPO_ROOT/CONTRIBUTING.md")"
FEAT='--title "feat(api): add a cool thing"'
FIX='--title "fix(portal): await console bind"'
DOUBLE_QUOTE_BACKSLASH_TITLE='feat(api): \q\q\q\q\q\q\q\q\q\q\q\q\q\q\q\q\q\q\q\q\q\q\q\q\q\q\q\q\q\q\q\q\q\q\q\q\q\q\q\q'
printf '%s' "$GRAPH" > "$TMP/body.md"
printf 'Adds a thing. Tested locally.\n' > "$TMP/prose.md"

# A fresh marker for every case ensures content checks, not stale review state,
# decide whether the body is accepted.
run_body() {
  write_marker "reviewed: body cases"
  run "$@"
}

run_body "short prose without a graph → allow" "gh pr create $FEAT --body 'Reduce duplicate CI jobs. Workflow tests passed.'" "passthrough"
run_body "bullets without a graph → allow" "gh pr create $FEAT --body '$BULLET_BODY'" "passthrough"
run_body "real example without a graph → allow" "gh pr create $FEAT --body '$EXAMPLE_BODY'" "passthrough"
run_body "sequence diagram without a call graph → allow" "gh pr create $FEAT --body '$SEQUENCE_BODY'" "passthrough"
run_body "comparison table without a graph → allow" "gh pr create $FEAT --body '$TABLE_BODY'" "passthrough"
run_body "fix description needs no graph or BUG marker → allow" "gh pr create $FIX --body '$FIX_GRAPH'" "passthrough"
run_body "fix without an associated issue → allow" "gh pr create $FIX --body 'Wait for console setup before attaching.'" "passthrough"
run_body "empty body → deny" "gh pr create $FEAT --body ''" "deny"
WHITESPACE_BODY=$' \n\t'
run_body "whitespace body → deny" "gh pr create $FEAT --body '$WHITESPACE_BODY'" "deny"
run_body "oversized description with valid legacy graph → deny" "gh pr create $FEAT --body '$LONG_BODY'" "deny"
run_body "unspaced text cannot evade the size limit → deny" "gh pr create $FEAT --body '$LONG_UNSPACED_BODY'" "deny"
run_body "120 words in short paragraphs at the boundary → allow" "gh pr create $FEAT --body '$LIMIT_WORDS_BODY'" "passthrough"
run_body "121 words → deny" "gh pr create $FEAT --body '$OVER_WORDS_BODY'" "deny"
run_body "80 Chinese characters at the paragraph boundary → allow" "gh pr create $FEAT --body '$LIMIT_CHARS_BODY'" "passthrough"
run_body "81 Chinese characters → deny" "gh pr create $FEAT --body '$OVER_CHARS_BODY'" "deny"
run_body "2000 four-byte characters → allow" "gh pr create $FEAT --body '$EMOJI_BODY'" "passthrough"
run_body "oversized argument → deny" "gh pr create $FEAT --body '$HUGE_BODY'" "deny"
run_body "long body edit → deny" "gh pr edit 42 $FEAT --body '$LONG_BODY'" "deny"
write_marker "reviewed: shorten description"
run "size rejection → deny" "gh pr create $FEAT --body '$LONG_BODY'" "deny"
run "size rejection preserves acknowledgment for corrected body" "gh pr create $FEAT --body '$BULLET_BODY'" "passthrough"
run "corrected body consumes acknowledgment" "gh pr create $FEAT --body '$BULLET_BODY'" "deny"
run_body "create without explicit body → deny" "gh pr create $FEAT" "deny"
run_body "create without explicit title → deny" "gh pr create --body '$GRAPH'" "deny"
run_body "double-quote backslashes count in the runtime title" \
  "gh pr create --title \"$DOUBLE_QUOTE_BACKSLASH_TITLE\" --body '$TITLE_GRAPH'" "deny"
DYNAMIC_BODY_COMMAND="gh pr create $FEAT --body \"\$(printf prose"$'\n'": '"$'\n'"$GRAPH"$'\n'"')\""
run_body "dynamic body cannot borrow inspected source text" "$DYNAMIC_BODY_COMMAND" "deny"
run_body "--fill is not an explicit body" "gh pr create $FEAT --fill" "deny"
run_body "--body-file prose → deny" "gh pr create $FEAT --body-file $TMP/prose.md" "deny"
run_body "--body-file=prose → deny" "gh pr create $FEAT --body-file=$TMP/prose.md" "deny"
run_body "-Fprose → deny" "gh pr create $FEAT -F$TMP/prose.md" "deny"

mv "$TMP/body.md" "$TMP/outside-body.md"
ln -s "$TMP/outside-body.md" "$TMP/body.md"
run_body "symlink --body-file → deny"          "gh pr create $FEAT --body-file $TMP/body.md"                 "deny"
rm -f "$TMP/body.md" "$TMP/outside-body.md"

mkfifo "$TMP/body.md"
write_marker "reviewed: FIFO body"
fifo_body_out="$(printf '%s' "gh pr create $FEAT --body-file $TMP/body.md" \
  | jq -Rs '{tool_input:{command:.}}' \
  | perl -e '$SIG{ALRM}=sub{exit 124}; alarm 2; exec @ARGV' "$HOOK" 2>/dev/null)"
fifo_body_rc=$?
fifo_body_decision="$(printf '%s' "$fifo_body_out" \
  | jq -r '.hookSpecificOutput.permissionDecision // "parse_error"' 2>/dev/null \
  || echo parse_error)"
if [[ "$fifo_body_rc" == 0 && "$fifo_body_decision" == deny ]]; then
  pass=$((pass + 1)); printf '  PASS  FIFO body file fails closed without blocking\n'
else
  fail=$((fail + 1)); printf '  FAIL  FIFO body file fails closed without blocking (rc=%s decision=%s)\n' \
    "$fifo_body_rc" "$fifo_body_decision"
fi
rm -f "$TMP/body.md" "$TMP/.agents/state/pr-reviewed.json"

printf '%s\n' "$GRAPH" > "$TMP/body.md"
awk 'BEGIN { for (i = 0; i < 1100000; i++) printf "x" }' >> "$TMP/body.md"
run_body "oversized --body-file → deny"        "gh pr create $FEAT --body-file $TMP/body.md"                 "deny"
printf '%s' "$GRAPH" > "$TMP/body.md"

run_hard_deny "compound mutation cannot invalidate an inspected body file" \
  "printf prose > $TMP/body.md; gh pr create $FEAT --body-file $TMP/body.md"
run_hard_deny "same-command redirection cannot truncate an inspected body file" \
  "gh pr create $FEAT --body-file $TMP/body.md > $TMP/body.md"

run_body "gh pr ready (no body flag) → allow" "gh pr ready 42"                                              "passthrough"
run_body "ready may explicitly undo draft status" "gh pr ready 42 --undo"                                  "passthrough"
run_body "ready tail repository override changes destination" \
  "gh pr ready 42 --repo other-owner/other-repo"                                                           "deny"
run_body "ready attached repository override changes destination" \
  "gh pr ready 42 -Rother-owner/other-repo"                                                                "deny"
run_body "dynamic ready tail cannot inject a repository override" \
  'gh pr ready 42 $READY_ARGS'                                                                              "deny"
run_body "ready URL selector cannot change repository" \
  "gh pr ready https://github.com/other/repo/pull/7"                                                       "deny"
run_body "body-only edit still requires the paired title" \
  "gh pr edit 42 --body '$GRAPH'"                                                                          "deny"
run_body "title-only edit still requires the paired body" \
  "gh pr edit 42 --title \"fix(api): reclassify description\""                                            "deny"
run_body "edit title and body are validated together" \
  "gh pr edit 42 --title \"fix(api): repair description\" --body '$FIX_GRAPH'"                            "passthrough"
run_body "dynamic edit operand cannot inject a body flag" \
  'gh pr edit 42 --add-label $EDIT_ARGS'                                                                    "deny"
run_body "empty quotes cannot launder an unquoted edit expansion" \
  "gh pr edit 42 --add-label \$EDIT_ARGS''"                                                                "deny"
run_body "edit URL selector cannot change repository" \
  "gh pr edit https://github.com/other/repo/pull/7 --add-label ready"                                      "deny"
run_body "valid graph body → allow"           "gh pr create $FEAT --body '$GRAPH'"                         "passthrough"
run_body "safe metadata may follow canonical prefix" \
  "gh pr create $FEAT --body '$GRAPH' --label ready --reviewer monalisa"                                   "passthrough"
run_body "head override is not bound to the review marker" \
  "gh pr create $FEAT --body '$GRAPH' --head other-user:unreviewed"                                        "deny"
run_body "base override changes the reviewed diff" \
  "gh pr create $FEAT --body '$GRAPH' --base unrelated-history"                                           "deny"
run_body "repository override changes the reviewed destination" \
  "gh pr create $FEAT --body '$GRAPH' --repo other-owner/other-repo"                                       "deny"
run_body "global repository override changes the reviewed destination" \
  "gh --repo other-owner/other-repo pr create $FEAT --body '$GRAPH'"                                       "deny"
run_body "attached global repository override changes the destination" \
  "gh -Rother-owner/other-repo pr create $FEAT --body '$GRAPH'"                                            "deny"
run_body "global hostname override changes the reviewed destination" \
  "gh --hostname enterprise.example pr create $FEAT --body '$GRAPH'"                                       "deny"
run_body "GH_REPO prefix changes the reviewed destination" \
  "GH_REPO=other-owner/other-repo gh pr create $FEAT --body '$GRAPH'"                                      "deny"
run_body "GH_HOST prefix changes the reviewed destination" \
  "GH_HOST=enterprise.example gh pr create $FEAT --body '$GRAPH'"                                          "deny"
run_body "env GH_REPO changes the reviewed destination" \
  "env GH_REPO=other-owner/other-repo gh pr create $FEAT --body '$GRAPH'"                                  "deny"
run_body "env chdir changes the reviewed checkout" \
  "env --chdir $TMP gh pr create $FEAT --body '$GRAPH'"                                                     "deny"
run_body "GIT_DIR prefix changes the reviewed checkout" \
  "GIT_DIR=$TMP/.git gh pr create $FEAT --body '$GRAPH'"                                                   "deny"
run_body "PATH prefix changes the inspected executable" \
  "PATH=$TMP/fake-bin gh pr create $FEAT --body '$GRAPH'"                                                  "deny"
run_body "even inert inline environment is outside the canonical contract" \
  "FOO=bar gh pr create $FEAT --body '$GRAPH'"                                                             "deny"
run_body "env assignments are outside the canonical contract" \
  "env FOO=bar gh pr create $FEAT --body '$GRAPH'"                                                         "deny"
write_marker "reviewed: inherited repository target"
GH_REPO=other-owner/other-repo run "inherited GH_REPO changes the reviewed destination" \
  "gh pr create $FEAT --body '$GRAPH'"                                                                      "deny"
write_marker "reviewed: inherited hostname target"
GH_HOST=enterprise.example run "inherited GH_HOST changes the reviewed destination" \
  "gh pr create $FEAT --body '$GRAPH'"                                                                      "deny"
write_marker "reviewed: inherited git directory"
GIT_DIR=$TMP/.git run "inherited GIT_DIR changes the reviewed checkout" \
  "gh pr create $FEAT --body '$GRAPH'"                                                                      "deny"
run_body "unquoted dynamic metadata cannot inject options" \
  "gh pr create $FEAT --body '$GRAPH' --label \$PR_LABEL"                                                   "deny"
run_body "empty quotes cannot launder an unquoted create expansion" \
  "gh pr create $FEAT --body '$GRAPH' --label ''\$PR_LABEL"                                                 "deny"
run_body "unquoted attached dynamic metadata cannot inject options" \
  "gh pr create $FEAT --body '$GRAPH' --label=\$PR_LABEL"                                                   "deny"
run_body "metadata glob cannot inject options" \
  "gh pr create $FEAT --body '$GRAPH' --label ?*"                                                          "deny"
run_body "attached metadata glob cannot inject options" \
  "gh pr create $FEAT --body '$GRAPH' --label=?*"                                                          "deny"
run_body "quoted dynamic metadata stays one operand" \
  "gh pr create $FEAT --body '$GRAPH' --label \"\$PR_LABEL\""                                             "passthrough"
run_body "metadata may consume a title-looking value" \
  "gh pr create $FEAT --body '$GRAPH' --label --title=not-a-title"                                         "passthrough"
run_body "metadata may consume a body-looking value" \
  "gh pr create $FEAT --body '$GRAPH' --label --body=prose"                                                "passthrough"
run_body "metadata may consume a body-file-looking value" \
  "gh pr create $FEAT --body '$GRAPH' --label -Fmissing"                                                   "passthrough"
write_marker "reviewed: dash-prefixed label value"
run "dash-prefixed metadata value does not exempt the create" \
  "gh pr create $FEAT --body '$GRAPH' --label --draft"                                                     "passthrough"
run "dash-prefixed metadata value still consumes the marker" \
  "gh pr create $FEAT --body '$GRAPH' --label --draft"                                                     "deny"
run_body "CRLF graph body → allow"            "gh pr create $FEAT --body '$GRAPH_CRLF'"                    "passthrough"
run_body "trailing sections after graph → allow" "gh pr create $FEAT --body '$GRAPH_WITH_TRAILING_SECTION'" "passthrough"
run_body "CONTRIBUTING.md's own example → allow" "gh pr create $FIX --body '$CONTRIB_BODY'"                "passthrough"
run_body "--body-file snapshot is not runtime-bound → deny" \
  "gh pr create $FEAT --body-file $TMP/body.md"                                                             "deny"
run_body "edit --body-file snapshot is not runtime-bound → deny" \
  "gh pr edit 42 --body-file $TMP/body.md"                                                                  "deny"
run_body "fix: concise description + issue → allow"   "gh pr create $FIX --body '$FIX_GRAPH'"                      "passthrough"

echo
echo "## Denial reasons are compact but preserve the typed-ack contract"
rm -f "$TMP/.agents/state/pr-reviewed.json"
long_tail="$(printf '%04096d' 0 | tr 0 x)"
ack_reason="$(reason_for "gh pr ready $long_tail")"
assert_reason_budget "missing-ack reason stays bounded even for a long command" "$ack_reason"
for contract in "request_user_input_async" "reviewed:" \
                ".agents/state/pr-reviewed.json" '"branch"' '"head"' '"message"' \
                "Abort" "Show me the diff" "Never infer" "fabricate"; do
  assert_reason_contains "ack reason keeps '$contract'" "$ack_reason" "$contract"
done

# A long but valid ref used to push the rendered reason over its cap. The generic
# fallback then removed the only instructions capable of satisfying the gate.
long_segment="$(printf '%0180d' 0 | tr 0 b)"
long_branch="$long_segment/$long_segment/$long_segment/$long_segment"
LONG_REPO="$TMP/long-branch-repo"
LONG_STATE="$TMP/long-branch-state"
git init -q -b "$long_branch" "$LONG_REPO"
git -C "$LONG_REPO" -c user.email=t@t -c user.name=t \
  commit -q --allow-empty -m init
mkdir -p "$LONG_STATE/.agents/state"
long_reason="$(reason_for_repo "$LONG_REPO" "$LONG_STATE" 'gh pr ready 42')"
assert_reason_budget "long-ref fallback stays bounded" "$long_reason"
for contract in "request_user_input_async" "reviewed:" \
                ".agents/state/pr-reviewed.json" '"branch"' '"head"' '"message"' \
                "Then retry" "Never infer" "fabricate"; do
  assert_reason_contains "long-ref fallback keeps '$contract'" "$long_reason" "$contract"
done
long_head="$(git -C "$LONG_REPO" rev-parse HEAD)"
jq -nc --arg branch "$long_branch" --arg head "$long_head" \
  --arg request "$(jq -r .id "$LONG_STATE/.agents/state/pr-review-request.json")" \
  '{branch:$branch,head:$head,message:"reviewed: long branch protocol",request:$request}' \
  > "$LONG_STATE/.agents/state/pr-reviewed.json"
long_retry="$(printf '%s' 'gh pr ready 42' | jq -Rs '{tool_input:{command:.}}' \
  | (cd "$LONG_REPO" && CLAUDE_PROJECT_DIR="$LONG_STATE" "$HOOK"))"
if [[ -z "$long_retry" && ! -e "$LONG_STATE/.agents/state/pr-reviewed.json" ]]; then
  pass=$((pass + 1)); printf '  PASS  long-ref fallback protocol reaches a successful retry\n'
else
  fail=$((fail + 1)); printf '  FAIL  long-ref fallback protocol reaches a successful retry\n'
fi

write_marker "reviewed: stale head"
jq '.head="deadbeef"' "$TMP/.agents/state/pr-reviewed.json" \
  > "$TMP/.agents/state/pr-reviewed.next.json"
mv "$TMP/.agents/state/pr-reviewed.next.json" "$TMP/.agents/state/pr-reviewed.json"
stale_reason="$(reason_for 'gh pr ready 42')"
assert_reason_budget "state-mismatch reason stays bounded" "$stale_reason"
assert_reason_contains "state-mismatch keeps native input route" \
  "$stale_reason" "reviewed:"
assert_reason_contains "state-mismatch keeps typed format" "$stale_reason" "reviewed:"

write_marker "yes"
malformed_reason="$(reason_for 'gh pr ready 42')"
assert_reason_budget "malformed-marker reason stays bounded" "$malformed_reason"
assert_reason_contains "malformed-marker keeps native input route" \
  "$malformed_reason" "reviewed:"
assert_reason_contains "malformed-marker keeps typed format" "$malformed_reason" "reviewed:"

assert_reason_budget "title denial stays bounded" \
  "$(reason_for "gh pr create --title \"add a cool thing\" --body '$TITLE_GRAPH'")"

write_marker "reviewed: concise body"
body_reason="$(reason_for "gh pr create $FEAT --body '$LONG_BODY'")"
assert_reason_budget "size denial stays bounded" "$body_reason"
assert_reason_contains "size denial uses reply-summary guidance" "$body_reason" 'visuals > tables > bullets > prose'

echo
echo "## Review prompts are loaded at the public hook boundary"
fixture_plugin="$TMP/prompt-plugin"
mkdir -p "$fixture_plugin/.agents/hooks" "$fixture_plugin/.agents/lib" "$fixture_plugin/.agents/prompts"
cp "$HOOK" "$fixture_plugin/.agents/hooks/"
cp "$REPO_ROOT/.agents/lib/"{verdict-audit-state,subagent,hook-host,reply-summary,github-writing,concise-writing,timed-user-prompt}.sh "$fixture_plugin/.agents/lib/"
cp "$REPO_ROOT/.agents/prompts/concise-writing.md" "$fixture_plugin/.agents/prompts/"
cp "$REPO_ROOT/.agents/prompts/timed-user-prompt.md" "$fixture_plugin/.agents/prompts/"
HOOK="$fixture_plugin/.agents/hooks/preflight-pr-review.sh"
cat > "$fixture_plugin/.agents/prompts/pr-review-ack.md" <<'PROMPT'
---
name: fixture
---
{{context}}
Fixture acknowledgment: {{review_question}}
PROMPT
printf 'Fixture description guidance\n' > "$fixture_plugin/.agents/prompts/pr-description-guidance.md"
printf 'First review question\n' > "$fixture_plugin/.agents/prompts/pr-review-question.md"
rm -f "$TMP/.agents/state/pr-reviewed.json"
assert_reason_contains "hook renders the prompt document" "$(reason_for 'gh pr ready 42')" \
  'Fixture acknowledgment: First review question'
# shellcheck disable=SC2016 # Prompt text must remain literal when loaded.
literal_question='Second question: $(printf injected) `printf injected`'
printf '%s\n' "$literal_question" > "$fixture_plugin/.agents/prompts/pr-review-question.md"
assert_reason_contains "next invocation reloads question as literal text" "$(reason_for 'gh pr ready 42')" "$literal_question"
printf '%0500d\n' 0 >> "$fixture_plugin/.agents/prompts/pr-review-ack.md"
fixture_long_reason="$(reason_for_repo "$LONG_REPO" "$LONG_STATE" 'gh pr ready 42')"
assert_reason_contains "long-ref recovery uses the same prompt document" \
  "$fixture_long_reason" "$literal_question"
assert_reason_contains "long-ref fixture reaches the recovery path" \
  "$fixture_long_reason" 'the detailed diagnostic exceeded 1200 bytes'
assert_reason_contains "body guidance is loaded from its document" \
  "$(reason_for "gh pr create $FEAT --body ''")" 'Fixture description guidance'

for prompt_name in pr-review-ack pr-review-question pr-description-guidance; do
  prompt_file="$fixture_plugin/.agents/prompts/$prompt_name.md"
  cp "$prompt_file" "$TMP/prompt-backup"
  for invalid in missing empty unresolved; do
    case "$invalid" in
      missing) rm -f "$prompt_file" ;;
      empty) printf ' \n' > "$prompt_file" ;;
      unresolved) printf '{{missing_value}}\n' > "$prompt_file" ;;
    esac
    write_marker 'reviewed: preserve this acknowledgment'
    jq -nc '{tool_input:{command:"gh pr ready 42"}}' | "$HOOK" \
      > "$TMP/prompt-stdout" 2> "$TMP/prompt-stderr"
    prompt_status=$?
    if [[ "$prompt_status" == 2 && ! -s "$TMP/prompt-stdout" \
       && -s "$TMP/prompt-stderr" && -f "$TMP/.agents/state/pr-reviewed.json" ]]; then
      pass=$((pass + 1)); printf '  PASS  %s %s fails closed without spending acknowledgment\n' "$invalid" "$prompt_name"
    else
      fail=$((fail + 1)); printf '  FAIL  %s %s must fail closed (exit=%s)\n' "$invalid" "$prompt_name" "$prompt_status"
    fi
  done
  cp "$TMP/prompt-backup" "$prompt_file"
done

printf '%01300d\n' 0 > "$fixture_plugin/.agents/prompts/pr-review-ack.md"
write_marker 'reviewed: preserve on oversized recovery'
jq -nc '{tool_input:{command:"gh pr ready 42"}}' | "$HOOK" \
  > "$TMP/prompt-stdout" 2> "$TMP/prompt-stderr"
prompt_status=$?
if [[ "$prompt_status" == 2 && ! -s "$TMP/prompt-stdout" \
   && -s "$TMP/prompt-stderr" && -f "$TMP/.agents/state/pr-reviewed.json" ]]; then
  pass=$((pass + 1)); printf '  PASS  oversized recovery fails closed without spending acknowledgment\n'
else
  fail=$((fail + 1)); printf '  FAIL  oversized recovery must fail closed (exit=%s)\n' "$prompt_status"
fi

echo "RESULT: $pass passed, $fail failed"
exit $(( fail > 0 ? 1 : 0 ))
