#!/usr/bin/env bash
# Exercise shipped PreToolUse commands followed by real Git, without harness markers.
set -uo pipefail
unset CLAUDECODE CODEX_SANDBOX AGENT_GATED GITHOOK_DELEGATED GITHOOK_KEEP_AUDIT
export BOXLITE_PR_WATCH=0 AGENT_TOOLING_REFRESH=0 AGENT_TOOLING_SYNC_ACTIVE=1
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export CODEX_BIN=/nonexistent-issue-299-codex
pass=0 fail=0
check() {
  local description="$1"; shift
  if "$@"; then
    pass=$((pass + 1)); printf 'PASS %s\n' "$description"
  else
    fail=$((fail + 1)); printf 'FAIL %s\n' "$description"
  fi
}
hash() { shasum -a 256 | awk '{print $1}'; }
stage_change() { printf 'change\n' >> "$1/f"; git -C "$1" add f; }

if [[ "${1:-}" == --worker ]]; then
  repo="$2" plugin="$3" manifest="$4" launcher="$5" scenario="$6"
  cd "$repo" || exit 2
  export PLUGIN_ROOT="$plugin" CLAUDE_PLUGIN_ROOT="$plugin" CLAUDE_PROJECT_DIR="$repo"
  hook_command="$(jq -r '.hooks.PreToolUse[].hooks[] | .command
    | select(contains("/preflight-commit-push.sh"))' "$plugin/hooks/$manifest")"
  case "$scenario" in
    missing-launcher) printf -v hook_command 'bash %q' "$plugin/.agents/hooks/preflight-commit-push.sh" ;;
    wrong-launcher) hook_command="${hook_command/--launcher-pid/--launcher-pid 1 extra}" ;;
    old-install)
      mkdir -p .agents/state/old/.githooks
      printf '#!/usr/bin/env bash\nexit 0\n' > .agents/state/old/.githooks/pre-commit
      chmod +x .agents/state/old/.githooks/pre-commit
      git config --worktree core.hooksPath "$repo/.agents/state/old/.githooks" ;;
    write-failed) printf 'unavailable\n' > "$(git rev-parse --absolute-git-dir)/agent-tooling-agent-shells" ;;
    lookup-failed)
      mkdir .agents/state/bin
      TEST_REAL_PS="$(command -v ps)"; export TEST_REAL_PS
      cat > .agents/state/bin/ps <<'PS'
#!/usr/bin/env bash
[[ "$*" != *' -o ppid=' ]] || exit 1
exec "$TEST_REAL_PS" "$@"
PS
      chmod +x .agents/state/bin/ps
      export PATH="$repo/.agents/state/bin:$PATH" ;;
  esac
  command="git commit -m 'test: change'"
  [[ "$scenario" != push ]] || command='git push origin HEAD:main'
  printf '%s' "$command" | jq -Rs '{tool_input:{command:.}}' > .agents/state/payload
  "$launcher" -c "$hook_command" < .agents/state/payload > .agents/state/pretool.out 2> .agents/state/pretool.err
  pretool_rc=$?
  case "$scenario" in
    missing-launcher|wrong-launcher|old-install|write-failed|lookup-failed)
      blocked=false
      if [[ "$pretool_rc" == 2 ]] || jq -e '.hookSpecificOutput.permissionDecision == "deny"' \
          .agents/state/pretool.out >/dev/null 2>&1; then blocked=true; fi
      check "$scenario blocks delegation" test "$blocked" = true
      check "$scenario publishes no handoff" test ! -e .agents/state/last-audit-handoff.json
      printf 'RESULT: %s passed, %s failed\n' "$pass" "$fail"
      (( fail == 0 )); exit $? ;;
  esac
  check "$manifest/$launcher/$scenario delegates" test "$pretool_rc:$(cat .agents/state/pretool.out)" = '0:'

  if [[ "$scenario" == hold || "$scenario" == hold-commit ]]; then
    touch .agents/state/ready ".agents/state/ready.$$"
    deadline=$((SECONDS + 15))
    while [[ ! -e .agents/state/release ]] && (( SECONDS < deadline )); do sleep 0.05; done
    [[ -e .agents/state/release ]] || exit 2
    [[ "$scenario" != hold ]] || exit "$fail"
  fi
  if [[ "$scenario" == worktree ]]; then
    check 'origin stays in its worktree even for the same agent process' \
      git -C "$repo-sibling" commit -qm 'test: other worktree'
    exit "$fail"
  fi

  if [[ "$scenario" == audited || "$scenario" == subject || "$scenario" == index ]]; then
    jq -nc --arg branch "$(git branch --show-current)" --arg head "$(git rev-parse HEAD)" \
      --arg diff "$(git diff --cached --no-ext-diff | hash)" \
      --arg command "$(printf '%s' "$command" | hash)" \
      --arg subject "$(printf 'test: change' | hash)" \
      '{branch:$branch,head:$head,command_kind:"commit",diff_hash:$diff,
        command_hash:$command,commit_subject_hash:$subject,verdict:"PASS",findings:[]}' \
      > .agents/state/last-audit.json
  fi

  origin_dir="$(git rev-parse --absolute-git-dir)/agent-tooling-agent-shells"
  record="$origin_dir/$$"
  case "$scenario" in
    malformed|symlink|fifo|directory|stale)
      mkdir -p "$origin_dir"
      rm -f "$record"
      case "$scenario" in
        malformed) printf 'invalid\n' > "$record" ;;
        symlink) ln -s "$repo/f" "$record" ;;
        fifo) mkfifo "$record" ;;
        directory) mkdir "$record" ;;
        stale) printf 'cksum-0-0\n' > "$record" ;;
      esac ;;
    index) stage_change "$repo" ;;
  esac

  before="$(git rev-parse HEAD)"
  case "$scenario" in
    push) git push origin HEAD:main > .agents/state/git.out 2>&1; rc=$? ;;
    subject) git commit -qm 'test: changed subject' > .agents/state/git.out 2>&1; rc=$? ;;
    *) git commit -qm 'test: change' > .agents/state/git.out 2>&1; rc=$? ;;
  esac
  case "$scenario" in
    audited|stale)
      check "$manifest/$launcher/$scenario commit succeeds" test "$rc" = 0
      if [[ "$scenario" == audited ]]; then
        check 'commit-msg consumes the matching audit' test ! -e .agents/state/last-audit.json
        printf 'git push origin HEAD:main' | jq -Rs '{tool_input:{command:.}}' > .agents/state/payload
        "$launcher" -c "$hook_command" < .agents/state/payload > .agents/state/pretool.out
        git push origin HEAD:main > .agents/state/git.out 2>&1; rc=$?
        check 'markerless push consumes the audited commit receipt' test "$rc" = 0
        check 'receipt was checked by pre-push' grep -q 'already passed its own audit' .agents/state/git.out
      fi ;;
    *)
      check "$manifest/$launcher/$scenario Git rejects" test "$rc" != 0
      case "$scenario" in
        subject) reason='Commit message does not match' ;;
        index) reason='Existing audit does not match current state' ;;
        malformed|symlink|fifo|directory) reason='agent origin' ;;
        *) reason='No CLAUDE.md audit found' ;;
      esac
      check "$manifest/$launcher/$scenario reaches audit boundary" grep -q "$reason" .agents/state/git.out
      check "$manifest/$launcher/$scenario preserves HEAD" test "$(git rev-parse HEAD)" = "$before" ;;
  esac
  printf 'RESULT: %s passed, %s failed\n' "$pass" "$fail"
  (( fail == 0 )); exit $?
fi

plugin_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
test_script="$plugin_root/tests/git-agent-origin.test.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
tooling="$scratch/tooling"
plugin="$tooling/plugins/boxlite-agent-tooling"
mkdir -p "$tooling/plugins"
cp -R "$plugin_root" "$plugin"
git -C "$tooling" init -q
git -C "$tooling" config user.email test@example.invalid
git -C "$tooling" config user.name tester
git -C "$tooling" add -A
git -C "$tooling" -c core.hooksPath= commit -qm tooling
revision="$(git -C "$tooling" rev-parse HEAD)"
case_number=0
setup() {
  case_number=$((case_number + 1))
  repo="$scratch/consumer-$case_number"
  git init -q "$repo"
  git -C "$repo" config user.email test@example.invalid
  git -C "$repo" config user.name tester
  mkdir -p "$repo/.agent-tooling" "$repo/.agents/state" "$repo/.git/agent-tooling"
  printf '.agents/state/\n.agent-tooling/\n' > "$repo/.git/info/exclude"
  printf '{"tooling":{"repository":"boxlite-ai/agent-tooling","ref":"main"}}\n' \
    > "$repo/.agent-tooling/profile.json"
  env -u AGENT_TOOLING_SYNC_ACTIVE -u AGENT_TOOLING_GUIDANCE_FORCE \
    bash "$plugin/scripts/sync-guidance.sh" "$repo" >/dev/null 2>&1 || return 2
  printf 'base\n' > "$repo/f"
  git -C "$repo" add -A
  git -C "$repo" -c core.hooksPath= commit -qm base
  ln -s "$tooling" "$repo/.git/agent-tooling/$revision"
  printf '%s\n' "$revision" > "$repo/.git/agent-tooling/current"
  git -C "$repo" config extensions.worktreeConfig true
  git -C "$repo" config --worktree core.hooksPath "$plugin/.githooks"
  git init --bare -q "$scratch/remote-$case_number"
  git -C "$repo" remote add origin "$scratch/remote-$case_number"
  git -C "$repo" push -q origin HEAD:main || return 2
  stage_change "$repo"
}
run_case() {
  local manifest="$1" launcher="$2" scenario="$3"
  setup || exit 2
  if [[ "$scenario" == push ]]; then git -C "$repo" commit -qm 'test: human change' || exit 2; fi
  if [[ "$scenario" == worktree ]]; then
    git -C "$repo" worktree add -q -b sibling "$repo-sibling" || exit 2
    git -C "$repo-sibling" config --worktree core.hooksPath "$plugin/.githooks"
    mkdir -p "$repo-sibling/.agent-tooling"
    cp "$repo/.agent-tooling/profile.json" "$repo-sibling/.agent-tooling/profile.json"
    stage_change "$repo-sibling"
  fi
  check "$manifest/$launcher/$scenario" bash "$test_script" --worker "$repo" "$plugin" "$manifest" "$launcher" "$scenario"
}
for manifest in hooks.json codex-hooks.json generic-hooks.json; do
  run_case "$manifest" /bin/bash commit
  run_case "$manifest" /bin/bash push
  run_case "$manifest" /bin/bash audited
done
for launcher in /bin/zsh /bin/sh; do
  [[ -x "$launcher" ]] || continue
  run_case generic-hooks.json "$launcher" commit
done
for scenario in subject index malformed symlink fifo directory stale \
  missing-launcher wrong-launcher old-install write-failed lookup-failed worktree; do
  run_case generic-hooks.json /bin/bash "$scenario"
done

# The human and agent share a worktree, but the human is outside the declaring runner.
setup || exit 2
bash "$test_script" --worker "$repo" "$plugin" generic-hooks.json /bin/bash hold > "$scratch/holder.out" 2>&1 &
holder=$!
deadline=$((SECONDS + 10))
while [[ ! -e "$repo/.agents/state/ready" ]] && (( SECONDS < deadline )); do sleep 0.05; done
check 'owner fixture reached PreToolUse' test -e "$repo/.agents/state/ready"
check 'human sibling remains exempt while the agent is alive' git -C "$repo" commit -qm 'test: human sibling'
touch "$repo/.agents/state/release"
check 'agent owner exits normally' wait "$holder"
stage_change "$repo"
check 'human remains exempt after agent exits' git -C "$repo" commit -qm 'test: human later'

# Both runners must remain gated after their shared command handoff is replaced.
setup || exit 2
holders=()
for owner in 1 2; do
  bash "$test_script" --worker "$repo" "$plugin" generic-hooks.json /bin/bash hold-commit \
    > "$scratch/concurrent-$owner.out" 2>&1 &
  holders+=("$!")
done
for holder in "${holders[@]}"; do
  deadline=$((SECONDS + 10))
  while [[ ! -e "$repo/.agents/state/ready.$holder" ]] && (( SECONDS < deadline )); do sleep 0.05; done
  check 'concurrent owner reached PreToolUse' test -e "$repo/.agents/state/ready.$holder"
done
touch "$repo/.agents/state/release"
for holder in "${holders[@]}"; do check 'concurrent owner remains audited' wait "$holder"; done
printf 'RESULT: %s passed, %s failed\n' "$pass" "$fail"
(( fail == 0 ))
