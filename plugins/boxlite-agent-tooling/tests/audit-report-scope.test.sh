#!/usr/bin/env bash
# Dispatch real hooks; attempt producers and stop handlers own all audit transitions.
set -euo pipefail
plugin="$(cd "$(dirname "$0")/.." && pwd -P)"
for library in verdict-audit-state audit-request audit-reflection audit-reflection-gate; do
  # shellcheck source=/dev/null
  source "$plugin/.agents/lib/$library.sh"
done
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
scratch="$(cd "$scratch" && pwd -P)"
repo="$scratch/repo"
git init -q "$repo"
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name fixture
git -C "$repo" config core.hooksPath /dev/null
printf '.agents/\n' > "$repo/.gitignore"
printf 'before\n' > "$repo/source"
git -C "$repo" add -A
git -C "$repo" commit -qm base
printf 'after\n' > "$repo/source"
git -C "$repo" add source
mkdir -p "$repo/.agents/state"
export CLAUDE_PROJECT_DIR="$repo" CLAUDE_PLUGIN_ROOT="$plugin" PLUGIN_ROOT="$plugin"
unset GIT_DIR GIT_WORK_TREE CODEX_SANDBOX CLAUDECODE AGENT_GATED GITHOOK_DELEGATED
serial=0
mode="$*"
expect() { # description, observed, expected
  [[ "$2" == "$3" ]] || { printf 'FAIL: %s: got %s, expected %s\n' "$1" "$2" "$3" >&2; exit 1; }
}
event() { # event, tool, input JSON
  jq -c --arg event "$1" --arg tool "$2" --argjson input "$3" \
    '. + {hook_event_name:$event,tool_name:$tool,tool_input:$input}' <<< "$payload"
}
fixture() { # host, commit|verdict, timeout
  host="$1"; kind="$2"; serial=$((serial + 1))
  export BOXLITE_HOOK_HOST="$host"
  session="report-$host-$kind-$serial"; worker="worker-$serial"
  scope="$(verdict_audit_scope_identity "$session" "$repo")"
  rm -f "$repo/.agents/state/last-audit.json"
  printf '101-201-1\n' > "$repo/.agents/state/verdict-prompt-epoch.$scope"
  auditor=commit-push-auditor; agent_path=commit_push_auditor
  [[ "$kind" != verdict ]] || { auditor=verdict-auditor; agent_path=verdict_auditor; }
  jq -nc --arg session "$session" --arg worker "$worker" --arg path "/root/$agent_path" \
    '{type:"session_meta",payload:{id:$worker,session_id:$session,thread_source:"subagent",
      source:{subagent:{thread_spawn:{parent_thread_id:$session,agent_path:$path}}}}}' > "$scratch/agent.jsonl"
  payload="$(jq -nc --arg cwd "$repo" --arg session "$session" --arg worker "$worker" \
    --arg type "boxlite-agent-tooling:$auditor" --arg host "$host" --arg path "$scratch/agent.jsonl" \
    '{cwd:$cwd,session_id:$session,agent_id:$worker,
      agent_type:(if $host=="claude" then $type else "default" end),
      transcript_path:$path,agent_transcript_path:$path,stop_hook_active:false}')"
  if [[ "$kind" == commit ]]; then
    jq -nc --arg session "$session" \
      '{session_id:$session,tool_input:{command:"git commit -m \"test: report scope\""}}' |
      (cd "$repo" && COMMIT_PUSH_AUDITOR_TIMEOUT="$3" GIT_CONFIG_COUNT=1 \
        GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0='' \
        bash "$plugin/.agents/hooks/preflight-commit-push.sh") > "$scratch/preflight"
  else
    request="301-401-$serial $(( $(date +%s) + 3600 )) cksum-1-1"
    printf '%s\n' "$request" > "$repo/.agents/state/verdict-request.$scope"
    audit_request_context_write "$repo" "$scope" "$request" 101-201-1
    VERDICT_AUDITOR_TIMEOUT="$3" bash "$plugin/.agents/hooks/audit-deadline.sh" \
      <<< "$(event SubagentStart Read '{}')"
  fi
  link="$repo/.agents/state/auditor-control/audit-task.$scope.$auditor.json"
  [[ -f "$link" ]] || { printf 'FAIL: production task setup\n' >&2; exit 1; }
  [[ "$#" -le 3 ]] || return 0
  if [[ "$kind" == commit ]]; then
    bash "$plugin/.agents/hooks/audit-deadline.sh" <<< "$(event SubagentStart Read '{}')"
    status=0
    AUDITOR_PROMPT_AFTER_SECONDS=0 bash "$plugin/.agents/hooks/auditor-control.sh" \
      <<< "$(event SubagentStart Read '{}')" > "$scratch/start.out" 2> "$scratch/start.err" || status=$?
    [[ "$status" == 0 || "$status" == 2 ]]
  fi
  task="$(cat "$link")"; dossier="$(jq -r .dossier_path <<< "$task")"
  expect 'worker ownership published before tools' "$(jq -r .host_agent_id <<< "$task")" "$worker"
  context="$(jq -c .context <<< "$task")"; id="$(jq -r .attempt_id <<< "$task")"
  expect 'producer opened attempt' "$(audit_reflection_gate "$context" inspect | jq .pending)" true
  if [[ "$3" == 1 ]]; then
    perl -e 'my $wait=$ARGV[0]-time+1; sleep $wait if $wait>0' "$(jq -r .deadline <<< "$task")"
  fi
}
dispatch() { # tool, input JSON
  local hook status packet manifest
  manifest=hooks.json; [[ "$host" != codex ]] || manifest=codex-hooks.json
  packet="$(event PreToolUse "$1" "$2")"
  design_status=unmatched; deadline_status=unmatched
  while IFS= read -r hook; do
    status=0
    (cd "$repo" && bash -c "$hook" <<< "$packet") > "$scratch/hook.out" 2> "$scratch/hook.err" || status=$?
    [[ "$status" == 0 || "$status" == 2 ]] || { cat "$scratch/hook.err" >&2; exit 1; }
    case "$hook" in
      *preflight-design-doc.sh*) design_status="$status"; cp "$scratch/hook.err" "$scratch/design.err" ;;
      *audit-deadline.sh*) deadline_status="$status"; cp "$scratch/hook.err" "$scratch/deadline.err" ;;
    esac
  done < <(jq -r --arg tool "$1" '.hooks.PreToolUse[] |
    select(.matcher as $matcher | $tool | test($matcher)) | .hooks[].command |
    select(contains("preflight-design-doc.sh") or contains("audit-deadline.sh"))' "$plugin/hooks/$manifest")
}
write_check() { # target, wanted design status
  dispatch Write "$(jq -nc --arg path "$1" '{file_path:$path,content:"{}"}')"
  if [[ "$design_status" != "$2" ]]; then cat "$scratch/design.err" >&2; fi
  expect "$host $kind assigned-report design decision" "$design_status" "$2"
}
stop() {
  local hook=audit-deadline.sh
  [[ "$kind" != commit ]] || hook='auditor-control.sh'
  bash "$plugin/.agents/hooks/$hook" <<< "$(event SubagentStop Read '{}')" > "$scratch/stop.out"
}
candidate() { # PASS|FAIL -> production-bound candidate file
  local history file
  history=''
  for file in "$repo"/.agents/state/audit-input-*.json; do
    if jq -e --arg id "$id" '.attempts[-1].id==$id' "$file" >/dev/null; then history="$file"; break; fi
  done
  [[ -n "$history" ]]
  jq --arg verdict "$1" --arg kind "$kind" '
    .attempts[-1].input.binding + {verdict:$verdict,advisories:["low: unchecked at deadline: execution records remain unread"],
      findings:(if $verdict=="FAIL" then ["high: confirmed defect: observed failing assertion"] else [] end)}
    + (if $kind=="verdict" then {proof:[]} else {commit_subject_hash:""} end)' "$history" > "$scratch/candidate"
  bash "$plugin/scripts/fixtures/audit-history-result.sh" \
    "$(jq -nc --arg path "$history" '{history_path:$path}')" "$scratch/candidate" bind
  jq '.history_review.coverage |= {reviewed:[],unread:(.reviewed + .unread)}' \
    "$scratch/candidate" > "$scratch/unread"
  mv "$scratch/unread" "$scratch/candidate"
}

if [[ "$mode" != --publication ]]; then
  for host in claude codex; do
    for kind in commit verdict; do
      fixture "$host" "$kind" 1
      dispatch Read "$(jq -nc --arg path "$repo/source" '{file_path:$path}')"
      expect 'investigation stops at deadline' "$deadline_status" 2
      before="$(audit_reflection_gate "$context" inspect | jq -c .state)"
      write_check "$dossier" 0
      expect 'assigned report passes deadline hook' "$deadline_status" 0
      expect 'permission does not record a decision' \
        "$(audit_reflection_gate "$context" inspect | jq -c .state)" "$before"
      [[ "$mode" != --reproducer ]] || exit 0
      dispatch apply_patch "$(jq -nc --arg path "$dossier" \
        '{command:("*** Begin Patch\n*** Add File: "+$path+"\n+{}\n*** End Patch")}')"
      expect 'single-report patch passes both hooks' "$design_status:$deadline_status" 0:0
      write_check "$repo/source" 2
      write_check "$repo/.agents/state/other-report.json" 2
      saved="$payload"
      payload="$(jq '.agent_type="general-purpose"' <<< "$saved")"; write_check "$dossier" 2
      payload="$(jq '.session_id="another-session"' <<< "$saved")"; write_check "$dossier" 2
      payload="$(jq '.agent_id="another-worker"' <<< "$saved")"; write_check "$dossier" 2
      if [[ "$host" == codex ]]; then
        jq -c '.payload.id="another-worker"' "$scratch/agent.jsonl" > "$scratch/other-agent.jsonl"
        payload="$(jq --arg path "$scratch/other-agent.jsonl" '.transcript_path=$path' <<< "$payload")"
        write_check "$dossier" 2
      fi
      payload="$saved"
      write_check "$(dirname "$dossier")/../state/$(basename "$dossier")" 2
      for tool in Edit MultiEdit NotebookEdit; do
        dispatch "$tool" "$(jq -nc --arg path "$dossier" '{file_path:$path,notebook_path:$path}')"
        expect 'other editor operations retain design gate' "$design_status" 2
      done
      dispatch apply_patch "$(jq -nc --arg path "$dossier" --arg source "$repo/source" \
        '{command:("*** Begin Patch\n*** Add File: "+$path+"\n+{}\n*** Delete File: "+$source+"\n*** End Patch")}')"
      expect 'mixed patch retains design gate' "$design_status" 2
      dispatch apply_patch "$(jq -nc --arg path "$dossier" \
        '{command:("*** Begin Patch\n*** Delete File: "+$path+"\n*** End Patch")}')"
      expect 'report deletion retains design gate' "$design_status" 2
      dispatch apply_patch "$(jq -nc --arg path "$dossier" --arg source "$repo/source" \
        '{command:("*** Begin Patch\n*** Update File: "+$path+"\n*** Move to: "+$source+"\n@@\n-a\n+b\n*** End Patch")}')"
      expect 'report move retains design gate' "$design_status" 2
      ln -s "$repo/source" "$dossier"; write_check "$dossier" 2; rm "$dossier"
      ln "$repo/source" "$dossier"; write_check "$dossier" 2; rm "$dossier"
      mkfifo "$dossier"; write_check "$dossier" 2; rm "$dossier"
      mkdir "$dossier"; write_check "$dossier" 2; rmdir "$dossier"
      printf '%s\n' "$task" > "$scratch/task"
      printf '{invalid\n' > "$link"; write_check "$dossier" 2; cp "$scratch/task" "$link"
      rm "$link"; mkfifo "$link"; write_check "$dossier" 2; rm "$link"; cp "$scratch/task" "$link"
      jq -c '.host_agent_id="another-worker"' "$scratch/task" > "$link"
      write_check "$dossier" 2; cp "$scratch/task" "$link"
      jq -c '.dossier_path += ".other"' "$scratch/task" > "$link"
      write_check "$dossier.other" 2; cp "$scratch/task" "$link"
      mv "$repo/.agents/state" "$repo/.agents/state-real"
      ln -s state-real "$repo/.agents/state"; write_check "$dossier" 2
      rm "$repo/.agents/state"; mv "$repo/.agents/state-real" "$repo/.agents/state"
      if [[ "$kind" == commit ]]; then
        printf '101-201-2\n' > "$repo/.agents/state/verdict-prompt-epoch.$scope"
        write_check "$dossier" 2
        printf '101-201-1\n' > "$repo/.agents/state/verdict-prompt-epoch.$scope"
      else
        mv "$repo/.agents/state/verdict-request.$scope" "$scratch/request"
        write_check "$dossier" 2
        mv "$scratch/request" "$repo/.agents/state/verdict-request.$scope"
      fi
      audit_reflection_gate "$context" error "$id" '"closed fixture attempt"' >/dev/null
      write_check "$dossier" 2
      fixture "$host" "$kind" 600; write_check "$dossier" 0
      printf 'PASS: %s %s report scope and rejected controls\n' "$host" "$kind"
      for outcome in PASS FAIL missing invalid; do
        fixture "$host" "$kind" 1
        if [[ "$outcome" != missing ]]; then
          write_check "$dossier" 0
          if [[ "$outcome" == invalid ]]; then printf '{invalid\n' > "$dossier"
          else candidate "$outcome"; cp "$scratch/candidate" "$dossier"; fi
        fi
        expect 'report write leaves attempt open' "$(audit_reflection_gate "$context" inspect | jq .pending)" true
        stop
        wanted="$outcome"
        if [[ "$outcome" == missing || "$outcome" == invalid ]]; then
          expect 'report-less stop resumes once' "$(jq -r .decision "$scratch/stop.out")" block
          payload="$(jq '.stop_hook_active=true' <<< "$payload")"; stop; wanted=ERROR
        fi
        recorded="$(audit_reflection_gate "$context" inspect)"
        expect 'stop records the decision' "$(jq -r '.state.attempts[-1].outcome.verdict' <<< "$recorded")" "$wanted"
        [[ ! -e "$link" ]]
        if [[ "$wanted" == PASS || "$wanted" == FAIL ]]; then
          jq -e '.state.attempts[-1].outcome | .deadline_review.recorded_at >= .deadline_review.deadline
            and (.history_review.coverage.unread | length)>0 and (.evidence.advisories | length)>0' <<< "$recorded" >/dev/null
        fi
        printf 'PASS: %s %s deadline -> report -> recorded %s\n' "$host" "$kind" "$wanted"
      done
    done
  done
fi

# Hold the asynchronous callback until after the published worker has stopped.
fixture claude commit 1 unbound
expect 'producer leaves worker binding for Start' "$(jq -r .host_agent_id "$link")" ''
start_packet="$(event SubagentStart Read '{}')"
start_hook="$(jq -r '.hooks.SubagentStart[].hooks[].command |
  select(contains("audit-deadline.sh"))' "$plugin/hooks/hooks.json")"
bash -c "$start_hook" <<< "$start_packet"
expect 'synchronous Start publishes worker before tools' "$(jq -r .host_agent_id "$link")" "$worker"
task="$(cat "$link")"; dossier="$(jq -r .dossier_path <<< "$task")"
context="$(jq -c .context <<< "$task")"; id="$(jq -r .attempt_id <<< "$task")"
mkfifo "$scratch/monitor-release"
monitor_hook="$(jq -r '.hooks.SubagentStart[].hooks[].command |
  select(contains("auditor-control.sh"))' "$plugin/hooks/hooks.json")"
(
  perl -e 'alarm 20; open my $f,"<",$ARGV[0] or exit 1; scalar <$f>' "$scratch/monitor-release"
  AUDITOR_PROMPT_AFTER_SECONDS=0 bash -c "$monitor_hook" \
    <<< "$start_packet" > "$scratch/monitor.out" 2> "$scratch/monitor.err"
) &
monitor_pid=$!
perl -e 'my $wait=$ARGV[0]-time+1; sleep $wait if $wait>0' "$(jq -r .deadline <<< "$task")"
write_check "$dossier" 0
candidate PASS; cp "$scratch/candidate" "$dossier"; stop
printf 'continue\n' > "$scratch/monitor-release"
monitor_status=0; wait "$monitor_pid" || monitor_status=$?
expect 'delayed monitor exits without a wake' "$monitor_status" 0
[[ ! -e "$repo/.agents/state/auditor-control/active.$scope.$auditor.json" ]]
[[ ! -e "$repo/.agents/state/auditor-control/escalation.$scope.$auditor.$worker.json" ]]
[[ ! -s "$scratch/monitor.out" && ! -s "$scratch/monitor.err" ]]
printf 'PASS: synchronous ownership precedes tools; delayed monitoring cannot reopen Stop\n'
[[ "$mode" != --publication ]] || exit 0

# Pause the real filesystem inspection, then revoke history without changing its task.
fixture claude commit 600
mkdir "$scratch/bin"
real_perl="$(command -v perl)"
export REPORT_SCOPE_REAL_PERL="$real_perl" REPORT_SCOPE_TARGET="$dossier"
export REPORT_SCOPE_READY="$scratch/ready" REPORT_SCOPE_RELEASE="$scratch/release"
mkfifo "$REPORT_SCOPE_RELEASE"
cat > "$scratch/bin/perl" <<'SH'
#!/usr/bin/env bash
last=''
for last; do :; done
if [[ "$last" == "$REPORT_SCOPE_TARGET" && ! -e "$REPORT_SCOPE_READY" ]]; then
  : > "$REPORT_SCOPE_READY"
  "$REPORT_SCOPE_REAL_PERL" -e 'alarm 20; open my $f,"<",$ARGV[0] or exit 1; scalar <$f>' "$REPORT_SCOPE_RELEASE"
fi
exec "$REPORT_SCOPE_REAL_PERL" "$@"
SH
chmod +x "$scratch/bin/perl"
packet="$(event PreToolUse Write "$(jq -nc --arg path "$dossier" '{file_path:$path,content:"{}"}')")"
(
  code=0
  PATH="$scratch/bin:$PATH" bash "$plugin/.agents/hooks/preflight-design-doc.sh" \
    <<< "$packet" > "$scratch/race.out" 2> "$scratch/race.err" || code=$?
  printf '%s\n' "$code" > "$scratch/race.status"
) &
barrier_pid=$!
barrier_limit=$(( $(date +%s) + 20 ))
until [[ -e "$REPORT_SCOPE_READY" ]]; do
  if [[ -e "$scratch/race.status" ]]; then cat "$scratch/race.err" >&2; exit 1; fi
  if (( $(date +%s) >= barrier_limit )); then
    kill "$barrier_pid" 2>/dev/null || true
    printf 'FAIL: target-inspection barrier was not reached\n' >&2
    exit 1
  fi
  kill -0 "$barrier_pid" || exit 1
  "$real_perl" -e 'select undef,undef,undef,0.05'
done
audit_reflection_gate "$context" error "$id" '"revoked during report inspection"' >/dev/null
expect 'revocation keeps the original task link' "$(cat "$link")" "$task"
printf 'continue\n' > "$REPORT_SCOPE_RELEASE"
wait "$barrier_pid"
expect 'revocation after initial checks retains design gate' "$(cat "$scratch/race.status")" 2
printf 'PASS: authority revoked during target inspection cannot authorize a report\n'
