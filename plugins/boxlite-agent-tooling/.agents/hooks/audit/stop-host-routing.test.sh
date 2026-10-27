#!/usr/bin/env bash
# Exercise provider selection through the real Stop checker and audit runner.
set -uo pipefail

plugin_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
checker="$plugin_root/.agents/hooks/audit/preflight-verdict-check.sh"
runner="$plugin_root/.agents/hooks/audit/run-verdict-audit.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/tools"
# Never reach installed model CLIs, even in missing-provider cases.
for tool in awk basename bash cat chmod cksum cp cut date dirname env find git grep \
  head id jq ln mkdir mkfifo mktemp mv paste perl ps rm rmdir sed sh shasum sleep sort \
  stat tail touch tr uname wc; do
  tool_path="$(command -v "$tool")" || exit 2
  ln -s "$tool_path" "$scratch/tools/$tool"
done
for tool in fuser lsof; do
  tool_path="$(command -v "$tool" 2>/dev/null)" || continue
  ln -s "$tool_path" "$scratch/tools/$tool"
done

cat > "$scratch/model" <<'MODEL'
#!/usr/bin/env bash
set -uo pipefail
if [[ "${1:-}" == --version ]]; then
  printf '%s\n' "$$" > "$ROUTE_CAPTURE/version"
  if [[ "${ROUTE_VERSION_HANG:-false}" == true ]]; then
    sleep 30
    printf 'escaped\n' > "$ROUTE_CAPTURE/escaped"
  fi
  printf 'test-cli\n'
  exit 0
fi
printf '%s\n' "${0##*/}" >> "$ROUTE_CAPTURE/calls"
printf '%s\n' "$@" > "$ROUTE_CAPTURE/args"
cat > "$ROUTE_CAPTURE/prompt"
[[ "${ROUTE_FAIL:-false}" != true ]] || exit 7
if [[ "$ROUTE_ROLE" == classifier ]]; then
  printf '%s\n' "${ROUTE_REPLY:-NO}"
else
  printf '{"branch":"main","head":"h","tree_hash":"t","generation":"%s","verdict":"PASS","proof":[],"findings":[]}' \
    "$VERDICT_AUDITOR_GENERATION" > "$VERDICT_AUDITOR_OUTPUT_FILE"
fi
MODEL
chmod +x "$scratch/model"

pass=0 fail=0 case_number=0
check_eq() {
  if [[ "$2" == "$3" ]]; then
    pass=$((pass + 1)); printf 'PASS %s\n' "$1"
  else
    fail=$((fail + 1)); printf 'FAIL %s: got <%s>, want <%s>\n' "$1" "$2" "$3"
  fi
}

run_case() { # role, host, scenario, expected provider, exit status, classifier rung
  local role="$1" host="$2" scenario="$3" expected="$4" expected_rc="$5"
  local rung="${6:-triage NO-allow}" repo rc calls observed_rung flag flags_ok=true version_pid
  case_number=$((case_number + 1))
  repo="$scratch/case-$case_number"
  mkdir -p "$repo/bin" "$repo/.agents/state" "$repo/.capture"
  git -C "$repo" init -q
  git -C "$repo" config user.email test@example.invalid
  git -C "$repo" config user.name test
  printf '.agents/state/\n.capture/\nbin/\ntranscript.jsonl\n' > "$repo/.gitignore"
  git -C "$repo" add .gitignore
  git -C "$repo" -c core.hooksPath=/dev/null commit -qm base
  printf '{"type":"assistant","message":{"content":[{"type":"text","text":"The culprit was a stale socket path."}]}}\n' \
    > "$repo/transcript.jsonl"
  cp "$scratch/model" "$repo/bin/claude"
  cp "$scratch/model" "$repo/bin/codex"
  if [[ "$scenario" == missing ]]; then rm "$repo/bin/$host"; fi
  if [[ "$scenario" == codex-only ]]; then rm "$repo/bin/claude"; fi
  (
    cd "$repo" || exit 2
    unset PLUGIN_ROOT CLAUDE_PLUGIN_ROOT BOXLITE_HOOK_HOST VERDICT_AUDITOR_CMD VERDICT_CLASSIFIER_CMD \
      VERDICT_EXTRACTOR_CMD VERDICT_GATE_HARD_BLOCK ROUTE_REPLY ROUTE_FAIL ROUTE_VERSION_HANG
    case "$host" in
      codex) export PLUGIN_ROOT="$plugin_root" ;;
      claude) export CLAUDE_PLUGIN_ROOT="$plugin_root" ;;
      ambiguous) export PLUGIN_ROOT="$plugin_root" CLAUDE_PLUGIN_ROOT="$plugin_root" ;;
    esac
    if [[ "$scenario" == aliases ]]; then
      export PLUGIN_ROOT="$plugin_root" CLAUDE_PLUGIN_ROOT="$plugin_root" BOXLITE_HOOK_HOST="$host"
    fi
    export PATH="$repo/bin:$scratch/tools" CODEX_BIN="$repo/bin/codex"
    export CLAUDE_PROJECT_DIR="$repo" ROUTE_CAPTURE="$repo/.capture" ROUTE_ROLE="$role"
    [[ "$scenario" != failure ]] || export ROUTE_FAIL=true
    [[ "$scenario" != malformed ]] || export ROUTE_REPLY=UNKNOWN
    [[ "$scenario" != version-hang ]] || export ROUTE_VERSION_HANG=true
    if [[ "$scenario" == override ]]; then
      if [[ "$role" == classifier ]]; then
        # Builtins only: the override sandbox forbids process forks.
        # shellcheck disable=SC2016 # Expand fixture variables in the child shell.
        export VERDICT_CLASSIFIER_CMD='while IFS= read -r line; do :; done; printf "override\n" > "$ROUTE_CAPTURE/calls"; printf "NO\n"'
      else
        # shellcheck disable=SC2016 # Expand fixture variables in the child shell.
        export VERDICT_AUDITOR_CMD='while IFS= read -r line; do :; done; printf "override\n" > "$ROUTE_CAPTURE/calls"; printf "{\"branch\":\"main\",\"head\":\"h\",\"tree_hash\":\"t\",\"verdict\":\"PASS\",\"proof\":[],\"findings\":[]}" > "$VERDICT_AUDITOR_OUTPUT_FILE"'
      fi
    fi
    if [[ "$role" == classifier ]]; then
      jq -nc --arg p "$repo/transcript.jsonl" '{transcript_path:$p,hook_event_name:"Stop"}' \
        | bash "$checker"
    else
      bash "$runner" "$repo/transcript.jsonl"
    fi
  ) > "$repo/.capture/output" 2> "$repo/.capture/error"
  rc=$?
  calls="$(cat "$repo/.capture/calls" 2>/dev/null || true)"
  check_eq "$role/$host/$scenario provider" "${calls:-none}" "$expected"
  check_eq "$role/$host/$scenario exit" "$rc" "$expected_rc"
  if [[ "$role" == classifier ]]; then
    observed_rung="$(awk '{print $(NF-1), $NF}' "$repo/.agents/state/verdict-decisions.log" 2>/dev/null)"
    check_eq "$role/$host/$scenario decision" "$observed_rung" "$rung"
  fi
  if [[ "$role/$host/$scenario" == classifier/codex/normal ]]; then
    for flag in --ignore-user-config --ephemeral read-only never hooks shell_tool multi_agent \
      --skip-git-repo-check project_doc_max_bytes=0; do
      grep -qxF -- "$flag" "$repo/.capture/args" || flags_ok=false
    done
    check_eq "Codex classifier keeps isolated CLI flags" "$flags_ok" true
    check_eq "Codex classifier receives production triage instructions" \
      "$(grep -cF 'Reply YES or NO only.' "$repo/.capture/prompt")" 1
    check_eq "Codex classifier receives the extracted turn" \
      "$(grep -cF 'The culprit was a stale socket path.' "$repo/.capture/prompt")" 1
  fi
  if [[ "$scenario" == version-hang ]]; then
    version_pid="$(cat "$repo/.capture/version" 2>/dev/null || true)"
    check_eq "Codex discovery reaches the supervised version probe" \
      "$([[ -f "$repo/.capture/version" ]] && echo yes || echo no)" yes
    check_eq "Codex discovery process is reaped at the deadline" \
      "$([[ "$version_pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$version_pid" 2>/dev/null && echo alive || echo stopped)" stopped
    check_eq "Codex discovery cannot outlive classification" \
      "$([[ -e "$repo/.capture/escaped" ]] && echo escaped || echo stopped)" stopped
  fi
}

for role in classifier auditor; do
  for host in codex claude; do
    run_case "$role" "$host" normal "$host" 0
    run_case "$role" "$host" aliases "$host" 0
    if [[ "$role" == classifier ]]; then
      run_case "$role" "$host" missing none 0 'regex none-allow'
      run_case "$role" "$host" failure "$host" 0 'regex none-allow'
    else
      run_case "$role" "$host" missing none 2
      run_case "$role" "$host" failure "$host" 1
    fi
    run_case "$role" "$host" override override 0
  done
  run_case "$role" unknown normal claude 0
  run_case "$role" ambiguous normal claude 0
done
run_case auditor unknown codex-only codex 0
run_case classifier codex malformed codex 0 'regex none-allow'
run_case classifier codex version-hang none 0 'regex none-allow'

printf '\nRESULT: %s passed, %s failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
