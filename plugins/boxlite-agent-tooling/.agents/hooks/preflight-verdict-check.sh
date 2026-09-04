#!/usr/bin/env bash
# Stop hook: gate the end of a turn on an audited verdict
# (see .claude/agents/verdict-auditor.md).
#
# DETECTION-TRIGGERED, finding-driven loops only. The trigger is the WHOLE FINAL
# TURN — every assistant text since the last real user message, read deterministically
# from the transcript: if it draws a conclusion the reader must take on TRUST — one
# whose evidence is not shown in the turn itself — the turn must end with a fresh
# session-scoped dossier under .agents/state/ (written by the verdict-auditor
# subagent). Chat, questions, and in-progress narration end freely.
# Turn-level, not last-fragment: findings asserted mid-turn cannot hide behind a
# closing "let me check X" (that miss shipped once, caught by a sibling session's
# decision log).
#
# Flow:
#   1. Dossier present, binding fresh + matching:
#        PASS         -> allow silently (consumed)
#        IN_PROGRESS  -> allow with note (consumed)
#        FAIL         -> block with the findings — THE one legitimate loop: it
#                        persists until the findings are addressed and a re-audit
#                        passes. A loop driven by real findings is the point.
#   1b. No dossier, but an older/asynchronous run-verdict-audit.sh is RUNNING —
#        audit_in_flight() decides,
#        on the lock's presence, its PID's liveness AND its freshness bound:
#        allow — the answer is being computed and no amount of re-blocking speeds it
#        up. Its verdict gates the NEXT turn end.
#   2. Dossier present but stale / mismatched (branch, HEAD, tree, age):
#        DISCARD it and fall through to detection. Never block on bookkeeping —
#        "the binding moved" is not a finding, and blocking on it was the
#        meaningless-loop class (e.g. a commit moving HEAD out from under a
#        dossier written seconds earlier).
#   3. No dossier: TRIAGE the turn text through a three-tier cascade, cheapest first,
#      so the 5-10s model round-trip is spent only where it actually decides anything:
#        A. harness noise (0ms)  — the assistant slot holds only text the HARNESS
#           wrote (API errors, quota notices, interruption markers). No model produced
#           it, so it cannot be a claim -> allow. 14.4% of real turns.
#        B. assertion-only (0ms) — a high-precision SUBSET of the fallback list below,
#           limited to forms that report an observation ("173/173 tests pass", a
#           whole-line "done.", a line-initial "Verified …") -> block. 10.7% of turns.
#        C. the model (5-10s)    — everything else. "Is this a conclusion the reader
#           must take on trust, with nothing shown that produced it?" A
#           fast model (haiku) answers YES/NO; when no model is reachable the static
#           pattern list below decides (deterministic fallback, e.g. sessions without
#           a model CLI). YES -> run the independent audit inside this Stop invocation;
#           PASS emits nothing, FAIL blocks with concise findings. NO -> allow
#           (announced to the human via systemMessage, invisible to the model).
#           Turns over 12 KB skip this duplicate model input and block for the
#           file-backed auditor instead.
#      No transcript (absent / unreadable / zero bytes) -> allow; nothing to judge.
#      A transcript WITH content but no assistant text is NOT that case — the hook
#      could not SEE the turn (unflushed final message, or a torn write jq could not
#      parse). It waits up to 2s for the text, then fails open under a `blind-allow`
#      rung so the log distinguishes "quiet session" from "gate never looked".
#
#      Tiers A and B are latency work ONLY — neither loosens the gate. A stays sound by
#      requiring EVERY non-empty line to be harness text, so a turn that errored and
#      retried still reaches B/C. B stays sound by leaving every prose-ambiguous
#      phrasing ("tests pass", "root cause is", "deploy is healthy") to the model:
#      removing the static false positives is the whole reason the model is primary,
#      and a turn merely DISCUSSING verdict phrasing must still be allowed.
#   4. Flush-race guard: the harness can fire Stop before appending the turn's final
#      message, leaving the PREVIOUS (already-gated) message last in the transcript.
#      The hook records the uuid it judged; if the newest uuid equals it, the hook
#      waits briefly for the fresh message and, failing that, allows — a message is
#      never judged twice.
#
# Wired in .claude/settings.json under hooks.Stop (no matcher — fires every turn end).
#
# Design notes
# ------------
# * Triage is the auditor's applicability judgment, extracted: the full verdict-auditor
#   already begins by deciding whether the message asserts anything verifiable. The
#   hook runs that ONE question on a small fast model (~seconds, message-only context)
#   so the expensive audit is spawned only when the answer is YES. Any classifier
#   failure — CLI absent, timeout, garbage output — degrades to the static pattern
#   list, and a pattern miss degrades further to the agent's CLAUDE.md duty: every
#   failure moves toward #915's honor system, never toward a trap. A false positive
#   costs ONE synchronous audit that trivially PASSes — a tax, not a loop. Fenced
#   blocks and multi-word code spans are stripped before triage so documentation ABOUT
#   verdicts does not trigger. The CLASSIFIER additionally keeps single-token spans,
#   because they are citations and its question turns on them; the pattern tiers keep
#   the old text, since anchoring on a token pulled to line start loosened them.
#   VERDICT_CLASSIFIER_CMD overrides the classifier (tests use stubs; set it to
#   `false` to force the regex path).
#
# * Why no loop can form: validation runs BEFORE detection, binding mismatches discard,
#   and detection invokes the runner synchronously. The runner owns cancellation and
#   publishes a generation-bound dossier; this hook re-enters its hardened validator.
#   PASS consumes the dossier with empty stdout. FAIL-with-findings is the only repeating
#   block, and unchanged session-scoped text reuses that FAIL instead of re-running the
#   model. A revised message receives a new generation and a new audit.
#
# * Tree-hash binding: at stop time the work is usually UNCOMMITTED (HEAD has not
#   moved), so HEAD alone can't tell "audited" from "changed since audit". The dossier
#   binds to a content-addressed hash of the full working tree via a throwaway index +
#   `git write-tree` (deterministic; no timestamps; never touches the real index). The
#   verdict-auditor computes it the SAME way. On mismatch the dossier is discarded and
#   the CURRENT message re-detected — so a real verdict still demands a fresh audit,
#   while a chat ending after the tree moved is not trapped.
#
# * One-shot consumption: the dossier is `rm -f`'d on every exit path except a
#   fresh+matching session-scoped FAIL (kept so the finding-driven block persists across
#   unchanged retries). A legacy caller has no message binding, so its FAIL is one-shot;
#   retaining it would poison unrelated later turns.
#
# * Soft mode is NOT enforcement: the Stop hook's systemMessage is shown to the HUMAN
#   only — the model never sees it (documented hook contract; only a block's `reason`
#   reaches the model). Soft mode exists as telemetry / emergency rollback (flip
#   VERDICT_GATE_HARD_BLOCK=0 in settings env; it propagates mid-session). Default: hard.
#
# Threat model & accepted limitations (this gate catches HONEST mistakes, not a malicious
# parent — the parent and the auditor share one filesystem + toolset):
#   - NOT forge-resistant: the parent can write the dossier itself. Real tamper-evidence
#     needs a signer the parent cannot impersonate (a harness-level capability) — a shell
#     hook cannot provide it. Out of scope by design.
#   - NOT evasion-resistant: a verdict worded outside the pattern list is not detected.
#     The patterns are a curated, tunable list (below) targeting how claims are actually
#     phrased; misses degrade to #915's self-declared behavior, never to a trap.
#
# Tests: bash .agents/hooks/preflight-verdict-check.test.sh
set -uo pipefail

for required_command in jq perl; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    printf 'preflight-verdict-check: required dependency not found: %s\n' \
      "$required_command" >&2
    exit 2
  fi
done

raw_payload="$(cat)"
payload="$(printf '%s' "$raw_payload" | jq -ecs '
  if length == 1 and (.[0] | type) == "object" then .[0] else empty end
' 2>/dev/null || true)"
if [[ -z "$payload" ]]; then
  printf 'preflight-verdict-check: expected exactly one JSON hook object.\n' >&2
  exit 1
fi
transcript_path="$(printf '%s' "$payload" | jq -r '.transcript_path // ""' 2>/dev/null || echo '')"
session_id="$(printf '%s' "$payload" | jq -r '
  if (.session_id | type) == "string" then .session_id else "" end
' 2>/dev/null || echo '')"
session_field_state="$(printf '%s' "$payload" | jq -r '
  if has("session_id") | not then "absent"
  elif (.session_id | type) == "string" and (.session_id | length) > 0 then "valid"
  else "invalid"
  end
' 2>/dev/null || echo 'invalid')"
if [[ "$session_field_state" == invalid ]]; then
  printf 'preflight-verdict-check: session_id must be a non-empty string when present.\n' >&2
  exit 1
fi
has_session_id=false
[[ "$session_field_state" == valid ]] && has_session_id=true
last_assistant_message="$(printf '%s' "$payload" | jq -r '
  if (.last_assistant_message | type) == "string" then .last_assistant_message else "" end
' 2>/dev/null || echo '')"
stop_hook_active="$(printf '%s' "$payload" | jq -r '
  if .stop_hook_active == true then "true" else "false" end
' 2>/dev/null || echo 'false')"

project_dir="${CLAUDE_PROJECT_DIR:-$PWD}"
if ! repo_root="$(git -C "$project_dir" rev-parse --show-toplevel 2>/dev/null)"; then
  printf 'preflight-verdict-check: project directory is not a Git repository: %s\n' \
    "$project_dir" >&2
  exit 1
fi
repo_root="$(cd "$repo_root" && pwd -P)"
project_dir="$repo_root"
tooling_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
audit_state_lib="$tooling_root/.agents/lib/verdict-audit-state.sh"
override_state_lib="$tooling_root/.agents/lib/auditor-override-state.sh"
if [[ ! -r "$audit_state_lib" || ! -r "$override_state_lib" ]]; then
  printf 'preflight-verdict-check: shared audit state libraries are unavailable.\n' >&2
  exit 1
fi
# shellcheck source=../lib/verdict-audit-state.sh
source "$audit_state_lib"
# shellcheck source=../lib/auditor-override-state.sh
source "$override_state_lib"
if [[ "$has_session_id" == "true" ]]; then
  if ! session_scope="$(verdict_audit_scope_from_hook_payload \
      "$payload" "$project_dir" 2>/dev/null)"; then
    printf 'preflight-verdict-check: could not derive the session audit scope.\n' >&2
    exit 1
  fi
else
  session_scope="-"
fi
branch="$(git -C "$repo_root" branch --show-current 2>/dev/null || echo '?')"
head="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || echo '?')"
state_dir="$project_dir/.agents/state"
stable_verdict_file="$(verdict_audit_state_path "$state_dir/last-verdict.json" "$session_scope")"
verdict_file="$stable_verdict_file"
auditor_verdict_file="$stable_verdict_file"
verdict_request_file="$(verdict_audit_state_path "$state_dir/verdict-request" "$session_scope")"
audit_decision_mutex_file="${verdict_request_file}.decision.mutex"
decision_lease_pid=0
decision_lease_status_file=""
active_bounded_capture_pgid=0
active_bounded_capture_group_owned=false
active_bounded_capture_marker=""
active_bounded_capture_marker_identity=""
bounded_override_isolation_checked=false
bounded_override_isolation_backend=""
bounded_override_isolation_tool=""
bounded_override_isolation_error_reported=false
bounded_capture_destination_identity=""
bounded_capture_pending_signal=""
# A FAILed dossier is parked here when the agent's fix moves the tree and invalidates
# the binding, so the next audit re-checks known findings instead of starting cold.
prev_verdict_file="$(verdict_audit_state_path "$state_dir/last-verdict.prev.json" "$session_scope")"
last_uuid_file="$(verdict_audit_state_path "$state_dir/verdict-last-uuid" "$session_scope")"
decision_log="$(verdict_audit_state_path "$state_dir/verdict-decisions.log" "$session_scope")"
# When Codex has no transcript, preserve its stable Stop message in the transcript
# shape the independent auditor already consumes. This is gitignored runtime state,
# not evidence invented by the gate: the text is copied byte-for-byte from the event.
payload_transcript_file="$(verdict_audit_state_path "$state_dir/verdict-stop-message.jsonl" "$session_scope")"
prompt_epoch_file="$(verdict_audit_state_path "$state_dir/verdict-prompt-epoch" "$session_scope")"
# Published by run-verdict-audit.sh while it holds the adjacent kernel lease. The first
# two fields are runner PID + deadline; later fields bind session, owner, and generation.
# Together they tell "the agent ignored the findings" from "the answer is coming".
audit_lock_file="$(verdict_audit_state_path "$state_dir/verdict-audit.lock" "$session_scope")"
audit_mutex_file="${audit_lock_file}.mutex"
# Ceiling on a lock's self-declared deadline. NOT max_age_seconds — dossier staleness
# and "how long may an audit run" are different questions. Shared with the runner so a
# configured timeout cannot publish a lease this gate immediately rejects.
# shellcheck disable=SC2154 # Assigned by verdict-audit-state.sh above.
audit_lock_max_seconds="$verdict_audit_lock_max_seconds"
max_age_seconds=600
classifier_timeout_seconds=20
classifier_max_bytes=12000
classifier_output_max_bytes=4096
verdict_output_max_bytes=8192
transcript_source_max_bytes=67108864
transcript_turn_max_bytes=262144
transcript_snapshot_truncated=false

# UserPromptSubmit atomically advances this session epoch before it waits for any gate
# mutex. This Stop invocation may trust authority only while the entry snapshot remains
# current. A missing marker is the initial epoch; malformed state fails closed.
read_prompt_epoch() {
  [[ "$session_scope" != "-" ]] || { printf '-'; return 0; }
  if [[ ! -e "$prompt_epoch_file" && ! -L "$prompt_epoch_file" ]]; then
    printf '-'
    return 0
  fi
  local epoch
  epoch="$(verdict_audit_read_single_record "$prompt_epoch_file" 2>/dev/null)" || return 1
  [[ "$epoch" =~ ^[1-9][0-9]*-[1-9][0-9]*-[0-9]+$ ]] || return 1
  printf '%s' "$epoch"
}
entry_prompt_epoch="$(read_prompt_epoch 2>/dev/null)" || entry_prompt_epoch=""
reentry_prompt_epoch="${VERDICT_STOP_REENTRY_EPOCH:-}"
prompt_epoch_is_current() {
  [[ "$session_scope" == "-" ]] && return 0
  [[ -n "$entry_prompt_epoch" ]] || return 1
  local current_epoch
  current_epoch="$(read_prompt_epoch 2>/dev/null)" || return 1
  [[ "$current_epoch" == "$entry_prompt_epoch" ]]
}

# One line per Stop decision (gitignored): timestamp, message identity, deciding
# rung, outcome — so "why did/didn't the gate fire?" is answerable with tail
# instead of fixture reconstruction. Best-effort: logging must never fail the
# hook. Rotated in place to stay bounded.
log_decision() {  # rung outcome
  local line
  mkdir -p "$(dirname "$decision_log")" 2>/dev/null || return 0
  line="$(date -u +%Y-%m-%dT%H:%M:%SZ) ${FINAL_ID:--} $1 $2"
  verdict_audit_append_log_line "$decision_log" "$line" 2>/dev/null || true
}

# UserPromptSubmit and dossier consumption share this short-lived session mutex. The
# prompt hook takes it before revocation; the Stop gate takes it before hiding a dossier
# under a quarantine name. That gives the two events one linear order and prevents an old
# generation from being restored or parked after cancellation already returned.
stop_decision_lease() {
  if [[ "$decision_lease_pid" =~ ^[1-9][0-9]*$ ]]; then
    kill -TERM "$decision_lease_pid" 2>/dev/null || true
    wait "$decision_lease_pid" 2>/dev/null || true
  fi
  decision_lease_pid=0
  [[ -z "$decision_lease_status_file" ]] || rm -f "$decision_lease_status_file"
  decision_lease_status_file=""
}

bounded_capture_group_has_residual_members() {  # sentinel-pid / pgid
  ps -axo pid=,pgid= 2>/dev/null \
    | awk -v leader="$1" -v group="$1" '
        $1 != leader && $2 == group { found = 1 }
        END { exit(found ? 0 : 1) }
      '
}

# Explicit command overrides are arbitrary shell and therefore a different trust
# boundary from the fixed Claude classifier route. macOS can permit the configured
# command while denying every fork; Linux can contain an ordinary helper tree inside a
# PID namespace whose init is killed with its unshare parent. Unsupported/locked-down
# hosts reject only the override and preserve the normal classifier fallback.
bounded_capture_override_isolation_error() {  # detail
  if [[ "$bounded_override_isolation_error_reported" != true ]]; then
    printf 'preflight-verdict-check: explicit classifier/extractor override requires OS process containment; %s.\n' \
      "$1" >&2
    bounded_override_isolation_error_reported=true
  fi
  return 1
}

bounded_capture_prepare_override_isolation() {
  local kernel
  if [[ "$bounded_override_isolation_checked" == true ]]; then
    [[ -n "$bounded_override_isolation_backend" ]] || return 1
    return 0
  fi
  bounded_override_isolation_checked=true
  bounded_override_isolation_backend=""
  bounded_override_isolation_tool=""
  kernel="$(uname -s 2>/dev/null)" || {
    bounded_capture_override_isolation_error \
      "the host kernel could not be identified"
    return 1
  }
  case "$kernel" in
    Darwin)
      [[ -x /usr/bin/sandbox-exec && -x /usr/bin/perl ]] || {
        bounded_capture_override_isolation_error \
          "macOS sandbox-exec is unavailable"
        return 1
      }
      /usr/bin/sandbox-exec -p \
        '(version 1) (allow default) (deny process-fork)' \
        /usr/bin/perl -e '
          my $child = fork();
          exit(defined($child) ? 1 : 0);
        ' </dev/null >/dev/null 2>&1 \
        || {
          bounded_capture_override_isolation_error \
            "macOS did not enforce the fork-denial sandbox profile"
          return 1
        }
      bounded_override_isolation_backend=darwin-sandbox
      bounded_override_isolation_tool=/usr/bin/sandbox-exec
      ;;
    Linux)
      if [[ -x /usr/bin/unshare ]]; then
        bounded_override_isolation_tool=/usr/bin/unshare
      elif [[ -x /bin/unshare ]]; then
        bounded_override_isolation_tool=/bin/unshare
      else
        bounded_capture_override_isolation_error \
          "Linux user/PID namespace support is unavailable"
        return 1
      fi
      "$bounded_override_isolation_tool" \
        --user --map-root-user --pid --fork --kill-child=KILL \
        /bin/sh -c 'exit 0' </dev/null >/dev/null 2>&1 \
        || {
          bounded_capture_override_isolation_error \
            "Linux user/PID namespace creation was denied"
          return 1
        }
      bounded_override_isolation_backend=linux-pid-namespace
      ;;
    *)
      bounded_capture_override_isolation_error \
        "kernel $kernel has no supported containment backend"
      return 1
      ;;
  esac
}

# A configured command may call setsid(2), so process-group ownership alone is not a
# complete lifetime boundary. Every command inherits an open descriptor for a private
# marker inode. fuser/lsof are optional accelerators on macOS; Linux can inspect the
# same descriptor identity through procfs. If none is available, the command is not
# launched: losing descendants is less safe than degrading this optional classifier or
# extractor to UNKNOWN/failed-snapshot behavior.
bounded_capture_marker_backend_available() {
  command -v fuser >/dev/null 2>&1 \
    || command -v lsof >/dev/null 2>&1 \
    || [[ -d /proc/$$/fd ]]
}

bounded_capture_marker_pids() {  # marker-path marker-device:inode
  local marker_path="$1" marker_identity="$2" listed=""
  verdict_audit_selected_identity_matches \
    "$marker_path" "$marker_identity" 2>/dev/null || return 1
  if command -v fuser >/dev/null 2>&1; then
    listed="$(fuser "$marker_path" 2>/dev/null || true)"
  fi
  if [[ -z "$listed" ]] && command -v lsof >/dev/null 2>&1; then
    listed="$(lsof -t -- "$marker_path" 2>/dev/null || true)"
  fi
  if [[ -z "$listed" && -d /proc/$$/fd ]]; then
    listed="$(perl -e '
      my ($device, $inode) = split(/:/, $ARGV[0], 2);
      exit 1 unless defined($inode) && $device =~ /\A[0-9]+\z/
        && $inode =~ /\A[0-9]+\z/;
      my %seen;
      for my $descriptor (glob("/proc/[1-9][0-9]*/fd/[0-9]*")) {
        my @held = stat($descriptor);
        next unless @held && $held[0] == $device && $held[1] == $inode;
        next unless $descriptor =~ m{\A/proc/([1-9][0-9]*)/fd/};
        print "$1\n" unless $seen{$1}++;
      }
    ' "$marker_identity" 2>/dev/null || true)"
  fi
  verdict_audit_selected_identity_matches \
    "$marker_path" "$marker_identity" 2>/dev/null || return 1
  printf '%s\n' "$listed" \
    | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^[1-9][0-9]*$/) print $i }' \
    | awk '!seen[$0]++'
}

bounded_capture_owned_process_records() {  # -> pid SP start-token
  local pid token holders
  [[ -n "$active_bounded_capture_marker" ]] || return 0
  holders="$(bounded_capture_marker_pids \
    "$active_bounded_capture_marker" \
    "$active_bounded_capture_marker_identity" 2>/dev/null)" || return 1
  while IFS= read -r pid; do
    [[ "$pid" =~ ^[1-9][0-9]*$ && "$pid" != "$$" ]] || continue
    token="$(verdict_audit_process_start_token "$pid" 2>/dev/null)" || continue
    printf '%s %s\n' "$pid" "$token"
  done <<< "$holders"
}

bounded_capture_merge_owned_process_records() {  # existing discovered -> union
  local existing_records="$1" discovered_records="$2"
  printf '%s\n%s\n' "$existing_records" "$discovered_records" \
    | awk '
        $1 ~ /^[1-9][0-9]*$/ && $2 ~ /^cksum-[0-9]+-[0-9]+$/ && NF == 2 {
          key = $1 " " $2
          if (!seen[key]++) print key
        }
      '
}

bounded_capture_signal_owned_records() {  # TERM|STOP|KILL records
  local signal_name="$1" records="$2" pid token extra current_token
  while read -r pid token extra; do
    [[ "$pid" =~ ^[1-9][0-9]*$ \
       && "$token" =~ ^cksum-[0-9]+-[0-9]+$ && -z "$extra" ]] || continue
    current_token="$(verdict_audit_process_start_token "$pid" 2>/dev/null)" \
      || continue
    [[ "$current_token" == "$token" ]] || continue
    current_token="$(verdict_audit_process_start_token "$pid" 2>/dev/null)" \
      || continue
    [[ "$current_token" == "$token" ]] || continue
    kill -"$signal_name" "$pid" 2>/dev/null || true
  done <<< "$records"
}

bounded_capture_records_have_live_identity() {  # records
  local records="$1" pid token extra current_token
  while read -r pid token extra; do
    [[ "$pid" =~ ^[1-9][0-9]*$ \
       && "$token" =~ ^cksum-[0-9]+-[0-9]+$ && -z "$extra" ]] || continue
    current_token="$(verdict_audit_process_start_token "$pid" 2>/dev/null)" \
      || continue
    [[ "$current_token" == "$token" ]] && return 0
  done <<< "$records"
  return 1
}

# Every small configurable subprocess below runs behind a deadline-bounded process-group
# sentinel. Retaining the leader until this function executes makes negative-PGID
# escalation safe even after the actual command has returned or closed stdout.
stop_bounded_capture_group() {
  local pgid="$active_bounded_capture_pgid" grace=2 reap_checks=100 freeze_round=0
  local owned_records="" refreshed_records="" current_records=""
  local cleanup_status=0 holders_clear=false holders_frozen=false
  local marker_path="$active_bounded_capture_marker"
  local marker_identity="$active_bounded_capture_marker_identity"
  if [[ -z "$marker_path" && ! "$pgid" =~ ^[1-9][0-9]*$ ]]; then
    active_bounded_capture_group_owned=false
    return 0
  fi
  if ! owned_records="$(bounded_capture_owned_process_records 2>/dev/null)"; then
    cleanup_status=1
    owned_records=""
  fi
  if [[ "$active_bounded_capture_group_owned" == true \
     && "$pgid" =~ ^[1-9][0-9]*$ && -z "$owned_records" ]]; then
    cleanup_status=1
  fi
  active_bounded_capture_pgid=0
  bounded_capture_signal_owned_records TERM "$owned_records"
  if [[ "$pgid" =~ ^[1-9][0-9]*$ \
     && "$active_bounded_capture_group_owned" == true ]]; then
    kill -TERM -- "-$pgid" 2>/dev/null || true
    kill -TERM "$pgid" 2>/dev/null || true
    while (( grace > 0 )) \
       && bounded_capture_group_has_residual_members "$pgid"; do
      perl -e 'select undef, undef, undef, 0.05'
      grace=$((grace - 1))
    done
    # Freeze every known producer before the final marker rescan. Any child forked by
    # a TERM handler before STOP inherits the descriptor and appears in that rescan;
    # after STOP no producer can create another holder before KILL.
    kill -STOP -- "-$pgid" 2>/dev/null || true
    kill -STOP "$pgid" 2>/dev/null || true
  elif [[ "$pgid" =~ ^[1-9][0-9]*$ ]]; then
    kill -TERM "$pgid" 2>/dev/null || true
    kill -STOP "$pgid" 2>/dev/null || true
  fi
  bounded_capture_signal_owned_records STOP "$owned_records"
  while (( freeze_round < 4 )); do
    if ! current_records="$(bounded_capture_owned_process_records 2>/dev/null)" \
       || [[ -z "$current_records" ]] \
       || ! refreshed_records="$(bounded_capture_merge_owned_process_records \
            "$owned_records" "$current_records")"; then
      cleanup_status=1
      break
    fi
    if [[ "$refreshed_records" == "$owned_records" ]]; then
      holders_frozen=true
      break
    fi
    owned_records="$refreshed_records"
    bounded_capture_signal_owned_records STOP "$owned_records"
    freeze_round=$((freeze_round + 1))
  done
  [[ "$holders_frozen" == true ]] || cleanup_status=1
  if [[ "$pgid" =~ ^[1-9][0-9]*$ \
     && "$active_bounded_capture_group_owned" == true ]]; then
    # The sentinel ignores TERM, preserving the owned PGID until escalation.
    kill -KILL -- "-$pgid" 2>/dev/null || true
    kill -KILL "$pgid" 2>/dev/null || true
    wait "$pgid" 2>/dev/null || true
  elif [[ "$pgid" =~ ^[1-9][0-9]*$ ]]; then
    kill -KILL "$pgid" 2>/dev/null || true
    wait "$pgid" 2>/dev/null || true
  fi
  bounded_capture_signal_owned_records KILL "$owned_records"
  while (( reap_checks > 0 )) \
     && bounded_capture_records_have_live_identity "$owned_records"; do
    perl -e 'select undef, undef, undef, 0.01'
    reap_checks=$((reap_checks - 1))
  done
  if ! bounded_capture_records_have_live_identity "$owned_records"; then
    holders_clear=true
  fi
  active_bounded_capture_group_owned=false
  [[ "$holders_clear" == true ]] || cleanup_status=1
  if (( cleanup_status == 0 )); then
    if [[ -n "$marker_path" \
       && "$marker_identity" =~ ^[0-9]+:[0-9]+$ ]] \
       && verdict_audit_unlink_if_identity \
            "$marker_path" "$marker_identity" 2>/dev/null; then
      active_bounded_capture_marker=""
      active_bounded_capture_marker_identity=""
    else
      cleanup_status=1
    fi
  fi
  return "$cleanup_status"
}

cleanup_bounded_capture_destination() {  # destination device:inode
  [[ "$2" =~ ^[0-9]+:[0-9]+$ ]] || return 1
  verdict_audit_unlink_if_identity "$1" "$2"
}

cleanup_stop_gate() {
  stop_bounded_capture_group
  stop_decision_lease
}

start_decision_lease() {
  [[ "$session_scope" != "-" ]] || return 0
  local status="" i=0 parent="$$"
  decision_lease_status_file="${audit_decision_mutex_file}.status-$$-${RANDOM:-0}"
  rm -f "$decision_lease_status_file"
  perl -MFcntl=:DEFAULT,:flock -e '
    my ($mutex_path, $status_path, $parent) = @ARGV;
    sub report {
      my ($value) = @_;
      sysopen(my $status, $status_path, O_WRONLY | O_CREAT | O_EXCL, 0600)
        or exit 2;
      print {$status} $value;
      close($status);
    }
    $SIG{ALRM} = sub { report("error") if !-e $status_path; exit 2 };
    alarm 2;
    exit 2 if lstat($mutex_path) && -l _;
    my $flags = O_RDWR | O_CREAT | O_APPEND | O_NONBLOCK;
    $flags |= Fcntl::O_NOFOLLOW() if defined &Fcntl::O_NOFOLLOW;
    sysopen(my $mutex, $mutex_path, $flags, 0600) or do { report("error"); exit 2 };
    my @opened = stat($mutex);
    my @named = lstat($mutex_path);
    if (!@opened || !@named || !-f $mutex || $opened[3] != 1
        || $opened[0] != $named[0] || $opened[1] != $named[1]) {
      report("error");
      exit 2;
    }
    flock($mutex, LOCK_EX) or do { report("error"); exit 2 };
    @opened = stat($mutex);
    @named = lstat($mutex_path);
    if (!@opened || !@named || !-f $mutex || $opened[3] != 1
        || $opened[0] != $named[0] || $opened[1] != $named[1]) {
      report("error");
      exit 2;
    }
    alarm 0;
    report("ok");
    select(undef, undef, undef, 0.05) while getppid() == $parent;
  ' "$audit_decision_mutex_file" "$decision_lease_status_file" "$parent" &
  decision_lease_pid=$!
  while (( i < 250 )); do
    if status="$(verdict_audit_read_single_record \
        "$decision_lease_status_file" 2>/dev/null)"; then
      break
    fi
    kill -0 "$decision_lease_pid" 2>/dev/null || break
    sleep 0.01
    (( i += 1 ))
  done
  rm -f "$decision_lease_status_file"
  decision_lease_status_file=""
  if [[ "$status" == ok ]]; then
    return 0
  fi
  stop_decision_lease
  return 1
}

trap cleanup_stop_gate EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

allow()           { exit 0; }                                              # let the turn end, silently
# User-visible, model-invisible allow: a Stop hook systemMessage is shown to the
# HUMAN in the terminal only — the model never sees it (documented hook contract).
# Announcing triage results this way keeps the agent's context clean and the gate
# loop-inert while the human still sees every decision live.
allow_with_note() {
  local note="$1" note_bytes
  note_bytes="$(LC_ALL=C printf '%s' "$note" | wc -c | tr -d ' ')"
  if (( note_bytes > verdict_output_max_bytes )); then
    note="Verdict: IN_PROGRESS — details omitted because the rendered note exceeded the 8192-byte safety limit. Proof remains deferred; inspect the session-scoped last-verdict dossier locally."
  fi
  jq -nc --arg m "$note" '{continue:true, systemMessage:$m}'
  exit 0
}
# Hard mode (default, set in settings.json env): block conditions block. Soft mode
# (VERDICT_GATE_HARD_BLOCK=0) demotes them to a user-visible nudge the MODEL never
# sees — rollback/telemetry only, see design notes.
block() {
  local reason="$1" reason_bytes
  # A prompt can arrive while a classifier or instruction renderer is still running.
  # Revalidate at the final output boundary so a superseded Stop can never publish a
  # late block even when every earlier branch check observed the old epoch.
  prompt_epoch_is_current || allow
  reason_bytes="$(LC_ALL=C printf '%s' "$reason" | wc -c | tr -d ' ')"
  if (( reason_bytes > verdict_output_max_bytes )); then
    reason="Verdict gate remains blocked: the rendered proof instruction exceeded the 8192-byte safety limit. Inspect the session-scoped .agents/state/last-verdict*.json dossier locally; do not paste its oversized findings or the transcript into chat. Run verdict-auditor synchronously against the current transcript (or use run-verdict-audit.sh headlessly), let the auditor write the dossier, then retry the ending. On PASS repeat the blocked answer; on FAIL revise it and re-audit."
  fi
  # Default HARD, matching the two doc sites above. Defaulting to soft meant only
  # Claude Code was gated: it is the sole caller that sets this, via settings.json
  # env, so the Codex registration in .codex/hooks.json and any direct invocation
  # got a non-blocking note instead. Set VERDICT_GATE_HARD_BLOCK=0 to roll back.
  if [[ "${VERDICT_GATE_HARD_BLOCK:-1}" != "0" ]]; then
    jq -nc --arg r "$reason" '{decision:"block", reason:$r}'
  else
    jq -nc --arg r "$reason" '{continue:true, systemMessage:("[verdict-gate] " + $r)}'
  fi
  exit 0
}

# audit_before_stop() re-enters this validator after the runner returns. Bind that child
# to the outer Stop's prompt epoch: a prompt arriving in the narrow fork/exec gap must
# release the abandoned Stop, not let the child adopt the new epoch and re-audit old text.
if [[ -n "$reentry_prompt_epoch" ]]; then
  if [[ "$reentry_prompt_epoch" != "-" \
     && ! "$reentry_prompt_epoch" =~ ^[1-9][0-9]*-[1-9][0-9]*-[0-9]+$ ]]; then
    printf 'preflight-verdict-check: invalid Stop re-entry prompt epoch.\n' >&2
    exit 1
  fi
  [[ "$entry_prompt_epoch" == "$reentry_prompt_epoch" ]] || allow
fi

# Content-addressed hash of the full working tree (tracked + untracked, full
# content), via a throwaway index. Deterministic and read-only w.r.t. the real
# index/tree. Keep IDENTICAL to the snippet in verdict-auditor.md.
compute_tree_hash() {
  local idx; idx="$(mktemp)"
  GIT_INDEX_FILE="$idx" git -C "$repo_root" read-tree HEAD >/dev/null 2>&1
  GIT_INDEX_FILE="$idx" git -C "$repo_root" add -A >/dev/null 2>&1
  GIT_INDEX_FILE="$idx" git -C "$repo_root" write-tree 2>/dev/null
  rm -f "$idx"
}

# A prompt-scoped user decision is a gate outcome, never an auditor verdict. It is
# checked before dossier consumption so a valid override can release a retained FAIL,
# but it writes only an OVERRIDDEN use record and never changes the dossier schema.
if [[ "$session_scope" != "-" ]] \
   && auditor_override_load_valid_grant \
        "$repo_root" "$session_scope" "$entry_prompt_epoch"; then
  override_tree_hash="$(compute_tree_hash)"
  override_context_hash="$(printf '%s\n%s\n%s\n' "$branch" "$head" "$override_tree_hash" \
    | shasum -a 256 | awk '{print $1}')"
  if ! auditor_override_log_use "$repo_root" "$session_scope" stop \
      "$override_context_hash" >/dev/null 2>&1; then
    block "Auditor override evidence could not be recorded; the verdict gate remains closed."
  fi
  log_decision override overridden-allow
  allow_with_note "[verdict-gate] OVERRIDDEN BY USER for this prompt; auditor PASS was not asserted"
fi

# ALL assistant text of the FINAL TURN — every text block emitted since the last
# real user message — from the session transcript (JSONL). Turn-level, not
# last-fragment: a finding asserted mid-turn ("no auto-start in the proxy")
# followed by closing narration ("let me check X") must still reach triage;
# judging only the trailing fragment let exactly that class slip (observed live
# in a sibling session's decision log).
#
# HARNESS-AGNOSTIC across the supported top-level envelopes: assistant/user roles
# may live on the record, its direct message or payload, or an actor with sibling
# output. Role-shaped objects nested inside tool calls/results are evidence, never
# conversation identities. Text comes from typed text blocks inside the recognized
# assistant envelope (Claude `text`, Codex `output_text`, and the actor/output form).
# A truly alien format may set VERDICT_EXTRACTOR_CMD in its own hook wiring (invoked
# with the transcript path as $1; stdout = the turn text to judge).
# Turn identity is a checksum of the joined text — content-derived, no
# per-harness ids — used by the never-judge-twice race guard.
# Empty transcript text is retried when the file has content: the hook can run before
# the harness flushes the final assistant record. Only after that bounded wait does
# the caller fall back to Codex Stop.last_assistant_message. Empty text after both
# sources means detection cannot run → allow (fail-open, never trap on absent state).
FINAL_ID=""
FINAL_TEXT=""
FINAL_SOURCE=""
PREEXTRACTED_FINAL_TEXT=""
AUDIT_TRANSCRIPT_SOURCE_PATH=""
AUDIT_TRANSCRIPT_REFRESHABLE=false
AUDIT_TRANSCRIPT_SOURCE_KIND="transcript"
identify_final_message() {
  FINAL_ID="cksum-$(printf '%s' "$FINAL_TEXT" | cksum | tr ' \t' '--')"
}
extract_final_message() {
  FINAL_ID=""; FINAL_TEXT=""; FINAL_SOURCE=""
  if [[ -n "$transcript_path" && -r "$transcript_path" ]]; then
    if [[ -n "${VERDICT_EXTRACTOR_CMD:-}" ]]; then
      FINAL_TEXT="$PREEXTRACTED_FINAL_TEXT"
    else
      FINAL_TEXT="$(jq -rs '
      def is_assistant: [.. | objects | select((.role? == "assistant") or (.type? == "assistant"))] | length > 0;
      def is_real_user:
        # A REAL user record carries a text-typed block at the TOP LEVEL of the
        # role-object own content (or plain string content). Tool results ride
        # user-role records with text nested INSIDE a tool_result block —
        # recursing into them (an earlier version did) turned every Read/Agent/
        # MCP result into a fake turn boundary and mid-turn findings escaped.
        ((.type? == "user") and
          ((.message.content? | type) == "string"
           or ([.message.content[]? | select((.type? // "") == "text")] | length) > 0))
        or ([.. | objects | select((.role? // "") == "user")
             | [.content[]? | select((.type? // "" | tostring) | test("text"))] | length]
            | any(. > 0));
      if length == 1
         and .[0].type? == "verdict_final_turn_snapshot"
         and (.[0].records? | type) == "array"
      then [.[0].records[]
            | select(.kind? == "assistant")
            | .texts[]? | strings]
           | join("\n\n")
      else . as $r
      | ([$r[] | is_real_user] | rindex(true)) as $lastu
      | $r[(if $lastu == null then 0 else $lastu + 1 end):]
      | [.[] | select(is_assistant) | (
          ([.. | objects | select((.type? // "" | tostring) | test("text")) | .text? // empty | strings] | join("\n")) as $typed
          | (if ($typed | length) > 0 then $typed
             else ([.. | objects | .text? // empty | strings] | join("\n")) end)
        ) | select(length > 0)]
      | join("\n\n")
      end' "$transcript_path" 2>/dev/null || true)"
    fi
  fi
  [[ -n "$FINAL_TEXT" ]] || return 0
  FINAL_SOURCE="$AUDIT_TRANSCRIPT_SOURCE_KIND"
  identify_final_message
}
use_payload_message() {
  [[ -n "$last_assistant_message" ]] || return 0
  FINAL_TEXT="$last_assistant_message"
  FINAL_SOURCE="payload"
  identify_final_message
}

# Resolve the current audited message before looking at any dossier. Session ownership
# alone is insufficient: a real steer stays in the same session, so the request must
# also bind the exact assistant turn text that the auditor was asked to judge.
transcript_had_content=false
resolve_final_message() {
  extract_final_message
  transcript_had_content=false
  [[ -n "$transcript_path" && -s "$transcript_path" ]] && transcript_had_content=true
  # Two reasons to re-read: no text yet, or a snapshot that came back unusable. The
  # second is the live-transcript race above — a hollow snapshot reads downstream as
  # "evidence incomplete" and forces a FAIL dossier the turn never earned, while the
  # settled file a few hundred milliseconds later extracts cleanly. The old
  # `!= failed` guard switched this loop off for precisely that case.
  # A final turn that genuinely exceeds the snapshot budget still ends truncated; it
  # spends the window first, which is the price of not having to tell the two apart.
  if [[ "$transcript_had_content" == true ]] \
     && { [[ -z "$FINAL_TEXT" && "$AUDIT_TRANSCRIPT_SOURCE_KIND" != failed ]] \
          || [[ "$transcript_snapshot_truncated" == true \
                && "$AUDIT_TRANSCRIPT_REFRESHABLE" == true ]]; }; then
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      sleep 0.2
      if [[ "$AUDIT_TRANSCRIPT_REFRESHABLE" == true ]]; then
        prepare_audit_transcript "$AUDIT_TRANSCRIPT_SOURCE_PATH" refresh \
          >/dev/null 2>&1 || true
      fi
      extract_final_message
      [[ -n "$FINAL_TEXT" && "$transcript_snapshot_truncated" != true ]] && break
    done
  fi
  # Codex permits a null transcript_path and supplies this stable Stop field. Apply it
  # only after the transcript flush window so one trailing fragment cannot hide an
  # earlier verdict from the same turn.
  [[ -z "$FINAL_TEXT" ]] && use_payload_message
}

# Fenced blocks go entirely: verdict phrasing quoted inside one is documentation, not a
# claim. Inline spans are split by whether they contain whitespace, because the two
# kinds do opposite things to triage:
#   * multi-word (`tests pass`, `root cause is`) — quoted prose. Stripped, same reason.
#   * single-token (`preflight-verdict-check.sh:262`, `audit_in_flight`) — a citation.
# Stripping BOTH deleted exactly the evidence the triage question asks about, so a turn
# that carefully cited its sources reached the classifier as fragments and got judged
# more harshly than one that asserted the same thing vaguely. Single tokens keep their
# text and lose their backticks so they read as ordinary words.
# TWO strippings, because the tiers want opposite things and a single one silently
# loosened tier A. Keeping a span's text drops its delimiters, which can pull the token
# to the START of a line: `API` Error handling is fixed → "API Error handling is fixed",
# which harness_patterns anchors on, so an assertion left through the top of the cascade
# with no model call. `Request` was aborted and `Credit` balance is too low do the same,
# and `Done. #1161` defeats the $-anchored done. assertion.
#   * static  — every span removed. What harness_patterns, assertion_patterns and
#               verdict_patterns were written against; they match multi-word PROSE, so
#               removing citations costs them nothing and keeps their anchors honest.
#   * cited   — single-token spans kept. Only the classifier sees this, because only its
#               question ("is the evidence shown?") depends on citations surviving.
strip_code_static() {
  awk 'BEGIN{fence=0} /^[[:space:]]*```/{fence=!fence; next} !fence' | sed -E 's/`[^`]*`//g'
}

# Spans are split by ALTERNATION, not by a regex over backticks: ``…`` are ambiguous
# delimiters, so `[^`]*[[:space:]][^`]*` happily matches the GAP BETWEEN two spans
# (dropping the prose between a citation and a quote) instead of the span itself.
strip_code_cited() {
  awk '
    BEGIN { fence = 0 }
    /^[[:space:]]*```/ { fence = !fence; next }
    fence { next }
    {
      n = split($0, p, "`")
      ends_tick = ($0 ~ /`$/)
      out = p[1]
      for (i = 2; i <= n; i++) {
        inside = (i % 2 == 0)
        # A trailing unterminated span is ordinary text, not a span.
        if (inside && i == n && !ends_tick) inside = 0
        if (inside) { if (p[i] !~ /[[:space:]]/) out = out p[i] }
        else out = out p[i]
      }
      print out
    }'
}

# ── Tier A: harness text sitting in the assistant slot ───────────────────────
# The assistant slot also carries text the HARNESS wrote, not the model: API errors,
# quota notices, interruption markers. It asserts nothing — no model produced it — so
# it can never be a verdict, and spending a 5-10s model round-trip to learn that is
# pure latency. Measured on this repo's transcripts: 81 of 563 real turns (14.4%) are
# exactly this, led by "API Error: 400 Your input exceeds the context window" (x43)
# and "No response requested." (x15).
#
# EVERY non-empty line must match — that is the soundness property, and it is why
# this is not a heuristic about content. Anchoring only the FIRST line would leak a
# real verdict whenever the model hit a transient error and then retried inside the
# same turn ("API Error: Overloaded" followed by "Root cause is X. All 53 tests
# pass."). Both variants catch the same 81 turns, so the strict one costs nothing.
harness_patterns='^[[:space:]]*(API Error'
harness_patterns+='|No response requested\.'
harness_patterns+='|Your organization has disabled'
harness_patterns+="|You've hit your (weekly|usage) limit"
harness_patterns+='|Credit balance is too low'
harness_patterns+='|Claude Code is unable'
harness_patterns+='|\[?Request (was )?(aborted|interrupted)'
harness_patterns+=')'
is_harness_noise() {  # $1 = stripped turn text
  local total matched
  total="$(printf '%s\n' "$1" | grep -c '[^[:space:]]' 2>/dev/null || true)"
  [[ "${total:-0}" -gt 0 ]] || return 1
  matched="$(printf '%s\n' "$1" | grep -Eic "$harness_patterns" 2>/dev/null || true)"
  [[ "${matched:-0}" -eq "$total" ]]
}

# ── Tier B: assertion-only claims, decidable without the model ───────────────
# A deliberately SMALL subset of the fallback list below: forms that REPORT an
# observation rather than name one — a concrete count ("173/173 tests pass"), a
# whole-line "done.", a line-initial "Verified …". Prose that merely DISCUSSES
# verdict phrasing ("people write things like tests pass or root cause is X") cannot
# take these shapes, so promoting them ahead of the classifier does not resurrect the
# static false positives the classifier exists to remove — which is why the ambiguous
# majority ("tests pass", "root cause is", "deploy is healthy") stays with the model.
# "deploy is healthy" is in the ambiguous group on purpose: "once the deploy is
# healthy, we proceed" is discussion, not a claim.
# Measured: 60/563 turns (10.7%), zero false blocks across 21 model-labelled hits.
assertion_patterns='[0-9]+ */ *[0-9]+ +(tests?|checks?|suites?|cases?)? *(pass(ed|ing|es)?|green)'
assertion_patterns+='|^[[:space:]]*done[.! ]*$'
assertion_patterns+='|^[[:space:]]*(verified|confirmed)[[:space:]]+[a-z]'

# Triage: ask a small fast model whether the turn draws a conclusion the reader has to
# take on TRUST. Not "does it state facts" — nearly all engineering status does, and
# that question blocked 18 of 22 sampled real turns while the 14 audits that actually
# completed in the same window produced zero findings. The cost of a false YES is
# minutes of blocked author; the cost of a false NO is one unaudited claim in a system
# whose own threat model is honest mistakes. Asking about EVIDENCE rather than facts
# took the same 22 turns to 3 YES with no turn newly blocking.
# Echoes YES / NO / UNKNOWN. UNKNOWN (no CLI, timeout, garbage) → regex fallback.
# VERDICT_CLASSIFIER_CMD overrides the whole classifier invocation (stdin = turn
# text, stdout = YES/NO); tests stub it, `false` forces UNKNOWN.
triage_prompt='Reply YES or NO only.

YES when the text declares a fix, root cause, no issues, done/ready/healthy state, or
similar conclusion without showing what proved it. NO for questions, plans,
narration, corrections, status, or claims supported inline by quoted output,
produced counts, a file:line citation, or a named commit.'
# The old parse was `tail -n1 | tr -dc 'A-Za-z'`, which turns any explanatory answer
# into a nonsense token — silently UNKNOWN, silently the regex fallback. That fired on
# real turns under the previous prompt too. Prefer the first token (a compliant model
# leads with it); accept a whole-output match; otherwise UNKNOWN. Deliberately NOT a
# scan for a bare "no" anywhere in the text: prose says "no" constantly, and reading an
# explanation as an allow would loosen the gate by accident.
classifier_answer() {  # stdin = raw model output; echoes YES/NO/UNKNOWN
  local raw first whole
  raw="$(cat)"
  first="$(printf '%s' "$raw" | awk 'NF{print toupper($1); exit}' | tr -dc 'A-Za-z')"
  # A model that reasons first and answers last ("Let me think.\nNO") was readable under
  # the old tail -n1 and must not regress to UNKNOWN. Whole LINE only — a prose line
  # ending in "no" is not an answer, and treating it as one would loosen the gate.
  last="$(printf '%s' "$raw" | awk 'NF{l=$0} END{print toupper(l)}' | tr -dc 'A-Za-z')"
  whole="$(printf '%s' "$raw" | tr -dc 'A-Za-z' | tr '[:lower:]' '[:upper:]')"
  case "$first" in YES|NO) printf '%s' "$first"; return ;; esac
  case "$last"  in YES|NO) printf '%s' "$last";  return ;; esac
  case "$whole" in YES|NO) printf '%s' "$whole"; return ;; esac
  printf 'UNKNOWN'
}

# Capture one command behind a stable process-group sentinel. The wrapper retains the
# FIFO writer until the command itself returns, so closing stdout early cannot disarm
# the same absolute deadline that bounds bytes, completion, termination, and reap.
capture_bounded_command() {  # stdin destination max-bytes timeout-seconds fixed|override command...
  local input_path="$1" destination="$2" max_bytes="$3" timeout_seconds="$4"
  local command_kind="$5"
  shift 5
  local channel_dir output_fifo status_file owner_marker owner_marker_identity
  local destination_identity_file owner_token sentinel_deadline
  local capture_status=0 command_status=125 destination_identity=""
  local teardown_status=0
  (( $# > 0 )) || return 1
  [[ "$max_bytes" =~ ^[1-9][0-9]*$ \
     && "$timeout_seconds" =~ ^[1-9][0-9]*$ \
     && ( "$command_kind" == fixed || "$command_kind" == override ) ]] \
    || return 1
  bounded_capture_destination_identity=""
  if [[ "$command_kind" == override ]]; then
    bounded_capture_prepare_override_isolation || return 1
  fi
  bounded_capture_marker_backend_available || return 1
  sentinel_deadline="$(( $(date +%s) + timeout_seconds + 2 ))"
  channel_dir="$(mktemp -d \
    "${TMPDIR:-/tmp}/boxlite-verdict-capture.XXXXXX" 2>/dev/null)" || return 1
  chmod 700 "$channel_dir" 2>/dev/null || {
    rmdir "$channel_dir" 2>/dev/null || true
    return 1
  }
  output_fifo="$channel_dir/stdout"
  status_file="$channel_dir/status"
  owner_marker="$channel_dir/owner"
  destination_identity_file="$channel_dir/destination-identity"
  if ! mkfifo "$output_fifo" 2>/dev/null; then
    rmdir "$channel_dir" 2>/dev/null || true
    return 1
  fi
  owner_marker_identity="$(verdict_audit_write_exclusive_regular_identity \
    "$owner_marker" </dev/null 2>/dev/null)" || {
    rm -f "$output_fifo" 2>/dev/null || true
    rmdir "$channel_dir" 2>/dev/null || true
    return 1
  }
  [[ "$owner_marker_identity" =~ ^[0-9]+:[0-9]+$ ]] || {
    verdict_audit_unlink_if_identity \
      "$owner_marker" "$owner_marker_identity" 2>/dev/null || true
    rm -f "$output_fifo" 2>/dev/null || true
    rmdir "$channel_dir" 2>/dev/null || true
    return 1
  }
  owner_token="capture-${owner_marker_identity//:/-}-$$-${RANDOM:-0}"
  active_bounded_capture_marker="$owner_marker"
  active_bounded_capture_marker_identity="$owner_marker_identity"

  # TERM/INT may arrive after fork but before $! is published. Defer only across that
  # narrow ownership gap, then replay the normal exit after both PGID and marker state
  # are visible to the EXIT cleanup trap.
  bounded_capture_pending_signal=""
  trap 'bounded_capture_pending_signal=TERM' TERM
  trap 'bounded_capture_pending_signal=INT' INT
  set -m
  (
    isolated_pid=0
    isolated_pending_signal=""
    kill_isolated_override() {
      local job_pid live_jobs
      live_jobs="$(jobs -p 2>/dev/null)"
      while IFS= read -r job_pid; do
        [[ "$job_pid" == "$isolated_pid" ]] || continue
        kill -KILL -- "-$isolated_pid" 2>/dev/null || true
        kill -KILL "$isolated_pid" 2>/dev/null || true
        wait "$isolated_pid" 2>/dev/null || true
        return 0
      done <<< "$live_jobs"
    }
    trap - EXIT
    trap ':' INT TERM
    exec 9<"$owner_marker" || exit 125
    export BOXLITE_VERDICT_CAPTURE_OWNER="$owner_token"
    if [[ "$command_kind" == override ]]; then
      # The nested job owns its own process group. On Darwin it is the group leader
      # (so setsid fails) and cannot fork; on Linux the unshare parent is the exact
      # kill-child authority for every process in the namespace.
      trap 'isolated_pending_signal=TERM' TERM
      trap 'isolated_pending_signal=INT' INT
      set -m
      if [[ "$bounded_override_isolation_backend" == darwin-sandbox ]]; then
        "$bounded_override_isolation_tool" -p \
          '(version 1) (allow default) (deny process-fork)' \
          "$@" <"$input_path" &
      else
        "$bounded_override_isolation_tool" \
          --user --map-root-user --pid --fork --kill-child=KILL -- \
          "$@" <"$input_path" &
      fi
      isolated_pid=$!
      set +m
      trap 'kill_isolated_override; exit 143' TERM
      trap 'kill_isolated_override; exit 130' INT
      case "$isolated_pending_signal" in
        TERM)
          kill_isolated_override
          exit 143
          ;;
        INT)
          kill_isolated_override
          exit 130
          ;;
      esac
      wait "$isolated_pid"
      command_status=$?
      trap ':' INT TERM
    else
      "$@" <"$input_path"
      command_status=$?
    fi
    # Publish status without using the output channel, then close the sentinel's
    # writer before sleeping. Descendants that retained stdout keep the reader (and
    # therefore its deadline) active until the entire group is quiescent.
    perl -MFcntl=:DEFAULT -e '
      my ($path, $status) = @ARGV;
      exit 1 unless $status =~ /\A(?:0|[1-9][0-9]{0,2})\z/;
      my $flags = O_WRONLY | O_CREAT | O_EXCL | O_NONBLOCK;
      $flags |= Fcntl::O_NOFOLLOW() if defined &Fcntl::O_NOFOLLOW;
      sysopen(my $fh, $path, $flags, 0600) or exit 1;
      my @opened = stat($fh);
      my @named = lstat($path);
      exit 1 unless @opened && @named && -f $fh && $opened[3] == 1
        && $opened[0] == $named[0] && $opened[1] == $named[1];
      print {$fh} "$status\n" or exit 1;
      close($fh) or exit 1;
    ' "$status_file" "$command_status" 2>/dev/null || true
    exec 1>&- 2>&-
    exec perl -e '
      my $deadline = shift;
      exit 1 unless $deadline =~ /\A[1-9][0-9]*\z/;
      $SIG{TERM} = sub {};
      $SIG{INT} = sub {};
      select(undef, undef, undef, 0.05) while time() <= $deadline;
    ' "$sentinel_deadline"
  ) >"$output_fifo" 2>/dev/null &
  active_bounded_capture_pgid=$!
  active_bounded_capture_group_owned=true
  set +m
  trap 'exit 143' TERM
  trap 'exit 130' INT
  case "$bounded_capture_pending_signal" in
    TERM) exit 143 ;;
    INT)  exit 130 ;;
  esac

  perl -e '
      my ($max, $timeout) = @ARGV;
      exit 1 unless $max =~ /^[1-9][0-9]*$/ && $timeout =~ /^[1-9][0-9]*$/;
      $SIG{ALRM} = sub { exit 1 };
      alarm $timeout;
      binmode(STDIN); binmode(STDOUT);
      my $body = "";
      while (length($body) <= $max) {
        my $chunk = "";
        my $count = sysread(STDIN, $chunk, $max + 1 - length($body));
        next if !defined($count) && $!{EINTR};
        exit 1 unless defined($count);
        last if $count == 0;
        $body .= $chunk;
      }
      exit 1 if length($body) > $max || index($body, "\0") >= 0;
      alarm 0;
      print STDOUT $body or exit 1;
    ' "$max_bytes" "$timeout_seconds" <"$output_fifo" \
      | verdict_audit_write_exclusive_regular_identity "$destination" \
          >"$destination_identity_file"
  capture_status=$?
  destination_identity="$(verdict_audit_read_single_record \
    "$destination_identity_file" 2>/dev/null)" || destination_identity=""
  if [[ "$destination_identity" =~ ^[0-9]+:[0-9]+$ ]] \
     && verdict_audit_selected_identity_matches \
          "$destination" "$destination_identity" 2>/dev/null; then
    bounded_capture_destination_identity="$destination_identity"
  else
    capture_status=1
  fi
  command_status="$(verdict_audit_read_single_record \
    "$status_file" 2>/dev/null)" || command_status=125

  stop_bounded_capture_group || teardown_status=1
  rm -f "$output_fifo" "$status_file" "$destination_identity_file" \
    2>/dev/null || true
  rmdir "$channel_dir" 2>/dev/null || true
  if (( capture_status != 0 )) \
     || (( teardown_status != 0 )) \
     || [[ ! "$command_status" =~ ^[0-9]+$ ]] \
     || (( command_status != 0 )); then
    cleanup_bounded_capture_destination \
      "$destination" "$bounded_capture_destination_identity" \
      2>/dev/null || true
    return 1
  fi
}

should_audit() {  # stdin-less; uses $1 as the stripped message; echoes YES/NO/UNKNOWN
  local msg="$1" out="" classifier_dir classifier_input classifier_output
  local classifier_output_identity=""
  # An exact `false` override is an explicit offline sentinel: its only possible result
  # is UNKNOWN, so avoid a supervised process launch and its teardown entirely.
  if [[ "${VERDICT_CLASSIFIER_CMD:-}" == false ]]; then
    echo UNKNOWN
    return 0
  fi
  classifier_dir="$(mktemp -d \
    "${TMPDIR:-/tmp}/boxlite-verdict-classifier.XXXXXX" 2>/dev/null)" || {
    echo UNKNOWN
    return 0
  }
  chmod 700 "$classifier_dir" 2>/dev/null || {
    rmdir "$classifier_dir" 2>/dev/null || true
    echo UNKNOWN
    return 0
  }
  classifier_input="$classifier_dir/input"
  classifier_output="$classifier_dir/output"
  bounded_capture_destination_identity=""
  if [[ -n "${VERDICT_CLASSIFIER_CMD:-}" ]]; then
    if printf '%s' "$msg" \
        | verdict_audit_write_exclusive_regular "$classifier_input" \
       && capture_bounded_command "$classifier_input" "$classifier_output" \
          "$classifier_output_max_bytes" "$classifier_timeout_seconds" \
          override bash -c "$VERDICT_CLASSIFIER_CMD"; then
      out="$(classifier_answer <"$classifier_output")"
    fi
  elif command -v claude >/dev/null 2>&1; then
    # Safe mode retains OAuth/keychain auth while dropping project/plugin/memory/hook
    # context. The custom system prompt + empty tools keep this a binary classifier;
    # --name also suppresses Claude Code's separate title-generation model request.
    if printf '<message>\n%s\n</message>\n' "$msg" \
        | verdict_audit_write_exclusive_regular "$classifier_input" \
       && capture_bounded_command "$classifier_input" "$classifier_output" \
          "$classifier_output_max_bytes" "$classifier_timeout_seconds" \
          fixed claude -p --safe-mode --tools "" --system-prompt "$triage_prompt" \
            --effort low --name verdict-classifier --no-session-persistence \
            --model claude-haiku-4-5-20251001; then
      out="$(classifier_answer <"$classifier_output")"
    fi
  fi
  classifier_output_identity="$bounded_capture_destination_identity"
  rm -f "$classifier_input" 2>/dev/null || true
  cleanup_bounded_capture_destination \
    "$classifier_output" "$classifier_output_identity" 2>/dev/null || true
  rmdir "$classifier_dir" 2>/dev/null || true
  case "$out" in
    YES) echo YES ;;
    NO)  echo NO ;;
    *)   echo UNKNOWN ;;
  esac
}

# Fallback claim patterns (ERE, matched case-insensitively) for when the classifier
# is unreachable. Targets how verdicts are actually phrased; tune here. A miss
# degrades to self-declared, a spurious hit costs one trivial-PASS audit.
verdict_patterns='root cause (is|was|confirmed|:)'
verdict_patterns+='|(all |the )?(tests?|suites?|checks?|builds?) (now |all |still )?(pass(es|ed|ing)?|green)'
verdict_patterns+='|[0-9]+/[0-9]+ (tests? )?(pass|passing|green)'
verdict_patterns+='|no (issues|bugs|problems|errors|regressions)'
verdict_patterns+='|(is|are|looks?) (now )?(fixed|resolved|working|correct|healthy|stable|live|green|complete|done|verified)'
verdict_patterns+='|works (as expected|correctly|now|fine|end.to.end)'
verdict_patterns+='|(fix|change|patch|refactor|migration) (works|is in place)'
verdict_patterns+='|(verified|confirmed)([;,.!]| that| the| it| locally| e2e| end)'
verdict_patterns+='|^[[:space:]]*(verified|confirmed) [a-z]'
verdict_patterns+='|deploy(ment|ed)? (is |looks? )?(healthy|live|successful|stable)'
verdict_patterns+='|^[[:space:]]*done[.! ]*$'
# Chinese claim phrasings (conservative set — the classifier handles languages the
# list never will; these keep the FALLBACK useful in bilingual sessions).
verdict_patterns+='|根因(是|为|：|:)'
verdict_patterns+='|(测试|用例)(全部|都|均)?(通过|绿)'
verdict_patterns+='|没有(问题|异常|回归)'
verdict_patterns+='|已(修复|解决|完成|验证)'
verdict_patterns+='|(部署|服务|线上)(正常|健康|稳定)'

# ── Synchronous audit request state ──────────────────────────────────────────
# The hook, not the model retry, owns audit orchestration. It writes a generation-bound
# request, runs the independent auditor, then re-enters this script so the existing
# dossier validator remains the single authority for PASS/FAIL. The runner prompt names
# prev_verdict_file, preserving finding-driven rechecks without exposing that control
# document in the host transcript.
audit_generation="legacy"
request_is_current=false
verdict_request_body=""

load_verdict_request() {
  if [[ "$session_scope" == "-" ]]; then
    audit_generation="legacy"
    request_is_current=true
    return 0
  fi
  local body generation deadline message_id extra now allow_canceled="${1:-false}"
  [[ -r "$verdict_request_file" ]] || return 1
  body="$(verdict_audit_read_single_record "$verdict_request_file" 2>/dev/null)" || return 1
  read -r generation deadline message_id extra <<< "$body"
  now="$(date +%s)"
  verdict_audit_epoch_is_bounded "$deadline" || return 1
  [[ "$generation" =~ ^[1-9][0-9]*-[0-9]+-[0-9]+$ \
     && "$message_id" =~ ^cksum-[0-9]+-[0-9]+$ \
     && -z "$extra" \
     && "$message_id" == "$FINAL_ID" ]] || return 1
  (( now <= deadline && deadline <= now + audit_lock_max_seconds )) || return 1
  audit_generation="$generation"
  audit_cancellation_file="$(verdict_audit_cancellation_path \
    "$state_dir" "$session_scope" "$audit_generation")"
  if [[ "$allow_canceled" != true ]] \
     && verdict_audit_cancellation_exists "$audit_cancellation_file"; then
    return 1
  fi
  if [[ "$session_scope" != "-" ]]; then
    auditor_verdict_file="${stable_verdict_file}.audit-${audit_generation}"
    if [[ -e "$auditor_verdict_file" || -L "$auditor_verdict_file" ]]; then
      verdict_file="$auditor_verdict_file"
    else
      verdict_file="$stable_verdict_file"
    fi
  fi
  verdict_request_body="$body"
  request_is_current=true
  return 0
}

consume_current_verdict_request() {
  if [[ "$session_scope" != "-" ]]; then
    [[ -n "$verdict_request_body" ]] || return 1
    prompt_epoch_is_current || return 1
    verdict_audit_remove_record_if_matches \
      "$verdict_request_file" "$verdict_request_body" >/dev/null 2>&1 || return 1
  fi
  prompt_epoch_is_current
}

current_verdict_request_matches() {
  [[ "$session_scope" != "-" ]] || return 0
  [[ -n "$verdict_request_body" ]] || return 1
  local current_body
  current_body="$(verdict_audit_read_single_record \
    "$verdict_request_file" 2>/dev/null)" || return 1
  [[ "$current_body" == "$verdict_request_body" ]]
}

current_verdict_authority_matches() {
  prompt_epoch_is_current || return 1
  current_verdict_request_matches || return 1
  [[ "$session_scope" == "-" ]] && return 0
  [[ -n "${audit_cancellation_file:-}" ]] || return 1
  ! verdict_audit_cancellation_exists "$audit_cancellation_file"
}

discard_path_for_current_epoch() {  # stable-path
  local stable_path="$1"
  prompt_epoch_is_current || return 1
  [[ -e "$stable_path" || -L "$stable_path" ]] || return 0
  local selected_identity
  selected_identity="$(verdict_audit_path_identity "$stable_path" 2>/dev/null)" \
    || return 1
  prompt_epoch_is_current || return 1
  verdict_audit_unlink_if_identity \
    "$stable_path" "$selected_identity" 2>/dev/null
}

# Replace a small session record without ever overwriting a pathname that a newer prompt
# or Stop may have published. A staged hardlink retains inode identity through the final
# epoch check, so rollback can retract only this invocation's write.
publish_record_for_current_epoch() {  # record-path body-without-LF
  local record_path="$1" record_body="$2"
  local staged="${record_path}.stage-$$-${RANDOM:-0}"
  local prior="${record_path}.prior-$$-${RANDOM:-0}" had_prior=false
  local staged_identity="" prior_identity="" cleanup_status=0
  prompt_epoch_is_current || return 1
  if ! staged_identity="$(printf '%s\n' "$record_body" \
      | verdict_audit_write_exclusive_regular_identity "$staged" 2>/dev/null)"; then
    return 1
  fi
  if ! prompt_epoch_is_current; then
    verdict_audit_unlink_if_identity \
      "$staged" "$staged_identity" 2>/dev/null || true
    return 1
  fi
  if [[ -e "$record_path" || -L "$record_path" ]]; then
    prior_identity="$(verdict_audit_path_identity "$record_path" 2>/dev/null)" || {
      verdict_audit_unlink_if_identity \
        "$staged" "$staged_identity" 2>/dev/null || true
      return 1
    }
    prompt_epoch_is_current || {
      verdict_audit_unlink_if_identity \
        "$staged" "$staged_identity" 2>/dev/null || true
      return 1
    }
    verdict_audit_rename_no_clobber_exact "$record_path" "$prior" 2>/dev/null || {
      verdict_audit_unlink_if_identity \
        "$staged" "$staged_identity" 2>/dev/null || true
      return 1
    }
    had_prior=true
    if ! verdict_audit_selected_identity_matches \
        "$prior" "$prior_identity" 2>/dev/null; then
      verdict_audit_restore_no_clobber "$prior" "$record_path" 2>/dev/null || true
      verdict_audit_unlink_if_identity \
        "$staged" "$staged_identity" 2>/dev/null || true
      return 1
    fi
    if ! prompt_epoch_is_current; then
      verdict_audit_unlink_if_identity \
        "$prior" "$prior_identity" 2>/dev/null || true
      verdict_audit_unlink_if_identity \
        "$staged" "$staged_identity" 2>/dev/null || true
      return 1
    fi
  fi
  if ! verdict_audit_link_no_clobber "$staged" "$record_path" 2>/dev/null; then
    if [[ "$had_prior" == true ]]; then
      verdict_audit_restore_no_clobber "$prior" "$record_path" 2>/dev/null || true
    fi
    verdict_audit_unlink_if_identity \
      "$staged" "$staged_identity" 2>/dev/null || true
    return 1
  fi
  if ! prompt_epoch_is_current; then
    verdict_audit_unlink_if_identity \
      "$record_path" "$staged_identity" 2>/dev/null || true
    if [[ "$had_prior" == true ]]; then
      verdict_audit_unlink_if_identity \
        "$prior" "$prior_identity" 2>/dev/null || true
    fi
    verdict_audit_unlink_if_identity \
      "$staged" "$staged_identity" 2>/dev/null || true
    return 1
  fi
  verdict_audit_unlink_if_identity \
    "$staged" "$staged_identity" 2>/dev/null || cleanup_status=1
  if [[ "$had_prior" == true ]]; then
    verdict_audit_unlink_if_identity \
      "$prior" "$prior_identity" 2>/dev/null || cleanup_status=1
  fi
  return "$cleanup_status"
}

discard_matching_json_generation() {  # json-path expected-generation
  local json_path="$1" expected="$2" quarantine snapshot json generation selected_identity
  [[ -e "$json_path" || -L "$json_path" ]] || return 0
  quarantine="${json_path}.discard-$$-${RANDOM:-0}"
  selected_identity="$(verdict_audit_path_identity "$json_path" 2>/dev/null)" \
    || return 1
  verdict_audit_rename_no_clobber_exact \
    "$json_path" "$quarantine" 2>/dev/null || return 1
  if ! verdict_audit_selected_identity_matches \
      "$quarantine" "$selected_identity" 2>/dev/null; then
    verdict_audit_restore_no_clobber \
      "$quarantine" "$json_path" 2>/dev/null || return 2
    return 1
  fi
  snapshot="$(verdict_audit_read_json_snapshot "$quarantine" 2>/dev/null)" \
    || snapshot=""
  json=""
  [[ "$snapshot" == *$'\n'* ]] && json="${snapshot#*$'\n'}"
  generation="$(printf '%s' "$json" | jq -rs '
    if length == 1 and (.[0] | type == "object")
       and (.[0].generation | type == "string")
    then .[0].generation else "" end
  ' 2>/dev/null || echo '')"
  if [[ "$generation" == "$expected" ]]; then
    verdict_audit_unlink_if_identity \
      "$quarantine" "$selected_identity" 2>/dev/null
    return $?
  fi
  verdict_audit_restore_no_clobber "$quarantine" "$json_path" 2>/dev/null || return 2
  return 1
}

ensure_verdict_request() {
  prompt_epoch_is_current || return 1
  if load_verdict_request; then
    if prompt_epoch_is_current; then
      return 0
    fi
    request_is_current=false
    return 1
  fi
  [[ "$session_scope" != "-" && -n "$FINAL_ID" ]] || return 0
  local deadline new_request_body existing_request_body invalid_identity
  audit_generation="$$-$(date +%s)-${RANDOM:-0}"
  auditor_verdict_file="${stable_verdict_file}.audit-${audit_generation}"
  verdict_file="$stable_verdict_file"
  deadline="$(( $(date +%s) + audit_lock_max_seconds ))"
  mkdir -p "$(dirname "$verdict_request_file")" 2>/dev/null || return 1
  prompt_epoch_is_current || return 1
  discard_path_for_current_epoch "$verdict_file" >/dev/null 2>&1 || true
  prompt_epoch_is_current || return 1
  if [[ -e "$verdict_request_file" || -L "$verdict_request_file" ]]; then
    if existing_request_body="$(verdict_audit_read_single_record \
        "$verdict_request_file" 2>/dev/null)"; then
      verdict_audit_remove_record_if_matches \
        "$verdict_request_file" "$existing_request_body" >/dev/null 2>&1 || return 1
    else
      # Invalid/FIFO/directory state cannot permanently suppress audit recovery. Rename
      # one exact pathname out of the publication slot, then remove only that selected
      # entry when it is a file/symlink or an empty directory.
      local invalid_request="${verdict_request_file}.invalid-$$-${RANDOM:-0}"
      invalid_identity="$(verdict_audit_path_identity \
        "$verdict_request_file" 2>/dev/null)" || return 1
      prompt_epoch_is_current || return 1
      verdict_audit_rename_exact \
        "$verdict_request_file" "$invalid_request" 2>/dev/null || return 1
      if ! verdict_audit_selected_identity_matches \
          "$invalid_request" "$invalid_identity" 2>/dev/null; then
        verdict_audit_restore_no_clobber \
          "$invalid_request" "$verdict_request_file" 2>/dev/null || true
        return 1
      fi
      rm -f "$invalid_request" 2>/dev/null || true
      rmdir "$invalid_request" 2>/dev/null || true
    fi
  fi
  prompt_epoch_is_current || return 1
  new_request_body="$audit_generation $deadline $FINAL_ID"
  if ! printf '%s\n' "$new_request_body" \
      | verdict_audit_write_exclusive_regular "$verdict_request_file" 2>/dev/null; then
    return 1
  fi
  verdict_request_body="$new_request_body"
  if ! prompt_epoch_is_current; then
    verdict_audit_remove_record_if_matches \
      "$verdict_request_file" "$verdict_request_body" >/dev/null 2>&1 || true
    request_is_current=false
    return 1
  fi
  request_is_current=true
}

write_payload_transcript() {
  local snapshot_body
  prompt_epoch_is_current || return 1
  mkdir -p "$(dirname "$payload_transcript_file")" 2>/dev/null || return 1
  snapshot_body="$(printf '%s' "$last_assistant_message" \
    | verdict_audit_message_snapshot "$transcript_turn_max_bytes")" || return 1
  transcript_snapshot_truncated="$(printf '%s' "$snapshot_body" \
    | jq -r 'if .truncated == true then "true" else "false" end' \
      2>/dev/null || echo true)"
  publish_record_for_current_epoch "$payload_transcript_file" "$snapshot_body"
}

write_failed_transcript_snapshot() {
  local snapshot_body
  snapshot_body="$(verdict_audit_failed_turn_snapshot \
    "$transcript_turn_max_bytes")" || return 1
  transcript_snapshot_truncated=true
  publish_record_for_current_epoch "$payload_transcript_file" "$snapshot_body"
}

# A failed extraction says nothing about the turn: the usual cause is that the read
# lost a race with the harness still appending to the transcript, because the
# extractor requires the source to be byte-identical across its two passes. Publish
# the hollow snapshot as before, but keep the source armed so resolve_final_message
# can re-read it — otherwise the one case that most needs a retry is the only one
# that cannot have one, and the turn dead-ends on evidence that was merely unread.
fail_transcript_snapshot() {  # source-path
  write_failed_transcript_snapshot || return 1
  AUDIT_TRANSCRIPT_SOURCE_KIND="failed"
  # Only a regular file can settle into a readable transcript. A FIFO, a directory or
  # a symlink is refused by the extractor for what it IS, and re-reading it would just
  # spend the retry window before failing exactly as before. Reserved for the built-in
  # reader: a custom extractor that busted its byte bound or its deadline busts them
  # again, so its failures stay one-shot.
  # `-f` alone would follow a symlink to a regular file and arm a source the extractor
  # rejects on sight (verdict-audit-state.sh refuses any path whose lstat is a link).
  [[ -f "$1" && ! -L "$1" ]] || return 0
  AUDIT_TRANSCRIPT_SOURCE_PATH="$1"
  AUDIT_TRANSCRIPT_REFRESHABLE=true
}

# A custom extractor is executable configuration, but its output is still untrusted.
# The shared capture facade keeps both bytes and producer lifetime behind one absolute
# deadline; a producer cannot close stdout and then strand this hook in a later wait.
capture_bounded_extractor() {  # source-path destination-path max-bytes
  local source_path="$1" destination="$2" max_bytes="$3"
  capture_bounded_command /dev/null "$destination" "$max_bytes" 5 override \
    bash -c "$VERDICT_EXTRACTOR_CMD \"\$1\"" _ "$source_path"
}

prepare_audit_transcript() {
  local source_path="${1:-$transcript_path}" refresh_mode="${2:-initial}"
  local staged extracted snapshot_body raw_snapshot raw_body extracted_snapshot
  local staged_identity="" extracted_identity="" snapshot_state=""
  if [[ "$refresh_mode" != refresh ]]; then
    transcript_snapshot_truncated=false
    PREEXTRACTED_FINAL_TEXT=""
    AUDIT_TRANSCRIPT_SOURCE_PATH=""
    AUDIT_TRANSCRIPT_REFRESHABLE=false
    AUDIT_TRANSCRIPT_SOURCE_KIND="transcript"
  fi
  # A refresh keeps what it cannot replace. Several exits below return without
  # publishing a snapshot — the source vanished, or the record could not be
  # written — and clearing the marker on entry would let one of them retire the
  # unusable-evidence state that the caller's gate depends on, ending the turn
  # UNJUDGED. Only a published snapshot may say what the evidence now is.
  if [[ -z "$source_path" || "$source_path" == /dev/null \
     || ( ! -e "$source_path" && ! -L "$source_path" ) ]]; then
    if [[ -n "$last_assistant_message" ]]; then
      write_payload_transcript || return 1
      transcript_path="$payload_transcript_file"
      AUDIT_TRANSCRIPT_SOURCE_KIND="payload"
    else
      transcript_path=""
      AUDIT_TRANSCRIPT_SOURCE_KIND="none"
    fi
    return 0
  fi
  if [[ -f "$source_path" && ! -s "$source_path" \
     && -z "$last_assistant_message" ]]; then
    transcript_path=""
    AUDIT_TRANSCRIPT_SOURCE_KIND="none"
    return 0
  fi
  staged="${payload_transcript_file}.stage-$$-${RANDOM:-0}"
  mkdir -p "$(dirname "$payload_transcript_file")" 2>/dev/null || return 1
  if [[ -n "${VERDICT_EXTRACTOR_CMD:-}" ]] \
     && raw_snapshot="$(verdict_audit_read_regular_state \
          "$source_path" "$transcript_source_max_bytes" json 2>/dev/null)" \
     && [[ "$raw_snapshot" == *$'\n'* ]]; then
    raw_body="${raw_snapshot#*$'\n'}"
    if ! staged_identity="$(printf '%s' "$raw_body" \
        | verdict_audit_write_exclusive_regular_identity \
            "$staged" 2>/dev/null)"; then
      [[ "$staged_identity" =~ ^[0-9]+:[0-9]+$ ]] \
        && cleanup_bounded_capture_destination \
            "$staged" "$staged_identity" 2>/dev/null || true
      write_failed_transcript_snapshot || return 1
      AUDIT_TRANSCRIPT_SOURCE_KIND="failed"
    else
      extracted="${staged}.extracted"
      if capture_bounded_extractor \
          "$staged" "$extracted" "$transcript_turn_max_bytes"; then
        extracted_identity="$bounded_capture_destination_identity"
        extracted_snapshot="$(verdict_audit_read_regular_state \
          "$extracted" "$transcript_turn_max_bytes" json 2>/dev/null)" \
          || extracted_snapshot=""
        if [[ "$extracted_snapshot" == *$'\n'* ]]; then
          PREEXTRACTED_FINAL_TEXT="${extracted_snapshot#*$'\n'}"
        else
          PREEXTRACTED_FINAL_TEXT=""
        fi
      else
        extracted_identity="$bounded_capture_destination_identity"
        PREEXTRACTED_FINAL_TEXT=""
      fi
      cleanup_bounded_capture_destination \
        "$extracted" "$extracted_identity" 2>/dev/null || true
      cleanup_bounded_capture_destination \
        "$staged" "$staged_identity" 2>/dev/null || true
      if [[ -n "$PREEXTRACTED_FINAL_TEXT" ]]; then
        last_assistant_message="$PREEXTRACTED_FINAL_TEXT"
        write_payload_transcript || return 1
        AUDIT_TRANSCRIPT_SOURCE_KIND="transcript"
      else
        write_failed_transcript_snapshot || return 1
        AUDIT_TRANSCRIPT_SOURCE_KIND="failed"
      fi
    fi
  elif staged_identity="$(verdict_audit_snapshot_final_turn_identity \
      "$source_path" "$staged" \
      "$transcript_source_max_bytes" "$transcript_turn_max_bytes")"; then
    snapshot_state="$(verdict_audit_read_regular_state \
      "$staged" "$transcript_turn_max_bytes" json \
      "$staged_identity" 2>/dev/null)" || snapshot_state=""
    if [[ "$snapshot_state" == *$'\n'* ]]; then
      snapshot_body="${snapshot_state#*$'\n'}"
      cleanup_bounded_capture_destination \
        "$staged" "$staged_identity" 2>/dev/null || true
      publish_record_for_current_epoch \
        "$payload_transcript_file" "$snapshot_body" || return 1
      transcript_snapshot_truncated="$(printf '%s' "$snapshot_body" \
        | jq -r 'if .truncated == true then "true" else "false" end' \
          2>/dev/null || echo true)"
      AUDIT_TRANSCRIPT_SOURCE_PATH="$source_path"
      AUDIT_TRANSCRIPT_REFRESHABLE=true
      AUDIT_TRANSCRIPT_SOURCE_KIND="transcript"
    else
      cleanup_bounded_capture_destination \
        "$staged" "$staged_identity" 2>/dev/null || true
      fail_transcript_snapshot "$source_path" || return 1
    fi
  else
    [[ "$staged_identity" =~ ^[0-9]+:[0-9]+$ ]] \
      && cleanup_bounded_capture_destination \
          "$staged" "$staged_identity" 2>/dev/null || true
    fail_transcript_snapshot "$source_path" || return 1
  fi
  transcript_path="$payload_transcript_file"
}

block_audit_infrastructure_failure() {  # reason
  # The message identity means "this turn was judged", not merely "triage started".
  # A runner/setup failure produced no verdict, so retaining the identity would make an
  # unchanged retry look like a transcript flush duplicate and escape through stale-allow.
  # Compare-and-remove preserves a concurrent Stop's replacement identity.
  verdict_audit_remove_record_if_matches \
    "$last_uuid_file" "$FINAL_ID" >/dev/null 2>&1 || true
  block "$1"
}

audit_before_stop() {  # trigger-reason
  local trigger_reason="$1" audit_transcript_path="$transcript_path"
  local runner="$tooling_root/.agents/hooks/run-verdict-audit.sh"
  local runner_status=0 runner_failure=""
  if ! ensure_verdict_request; then
    block_audit_infrastructure_failure "${trigger_reason}

Verdict audit could not start because its generation-bound request was not recorded."
  fi
  prompt_epoch_is_current || allow
  if [[ ! -r "$runner" ]]; then
    block_audit_infrastructure_failure "${trigger_reason}

Verdict audit runner is unavailable at ${runner}."
  fi
  CLAUDE_PROJECT_DIR="$project_dir" bash "$runner" "$audit_transcript_path" \
    "$session_id" "$audit_generation" "$session_scope" >/dev/null 2>&1 \
    || runner_status=$?
  prompt_epoch_is_current || allow
  if (( runner_status != 0 )); then
    case "$runner_status" in
      1) runner_failure="the independent auditor did not produce a valid dossier" ;;
      2) runner_failure="no independent auditor runner is available" ;;
      130|143) runner_failure="the independent audit was canceled before completion" ;;
      *) runner_failure="the independent auditor exited with status ${runner_status}" ;;
    esac
    block_audit_infrastructure_failure "${trigger_reason}

Verdict audit could not complete: ${runner_failure}. Retry after restoring the auditor."
  fi

  # Re-enter the hardened dossier path instead of duplicating its generation, binding,
  # inode, and prompt-epoch checks here. PASS returns empty stdout; FAIL returns only
  # its concise findings. The runner output itself never reaches the host transcript.
  printf '%s' "$raw_payload" \
    | ( cd "$repo_root" \
        && CLAUDE_PROJECT_DIR="$project_dir" \
          VERDICT_STOP_REENTRY_EPOCH="$entry_prompt_epoch" bash "${BASH_SOURCE[0]}" )
  exit $?
}
# ─────────────────────────────────────────────────────────────────────────────

# A parked FAIL is only useful to the NEXT audit of the SAME round. If nobody ever
# claimed it — the round was abandoned, the user changed topic, no re-audit ran — it must
# not be handed to an auditor judging unrelated work. That is the identical hazard the
# park-side age gate closes, one site over: gating only the write bounds staleness at
# park time, while this file is read on every later block. Left unexpired it manufactures
# findings about dead work, and since the auditor is told "a finding you cannot confirm as
# addressed stays a finding", those become a FAIL — re-entering the meaningless-loop class
# item 2 of this header exists to eliminate.
expire_stale_prev() {
  prompt_epoch_is_current || return 0
  [[ -e "$prev_verdict_file" || -L "$prev_verdict_file" ]] || return 0
  local parked_quarantine="${prev_verdict_file}.expire-$$-${RANDOM:-0}"
  local parked_identity=""
  local parked_snapshot="" parked_mtime="" parked_age=0
  parked_identity="$(verdict_audit_path_identity "$prev_verdict_file" 2>/dev/null)" \
    || return 0
  prompt_epoch_is_current || return 0
  verdict_audit_rename_exact \
    "$prev_verdict_file" "$parked_quarantine" 2>/dev/null || return 0
  if ! verdict_audit_selected_identity_matches \
      "$parked_quarantine" "$parked_identity" 2>/dev/null; then
    verdict_audit_restore_no_clobber \
      "$parked_quarantine" "$prev_verdict_file" 2>/dev/null || true
    return 0
  fi
  if ! prompt_epoch_is_current; then
    verdict_audit_unlink_if_identity \
      "$parked_quarantine" "$parked_identity" 2>/dev/null || true
    return 0
  fi
  if parked_snapshot="$(verdict_audit_read_json_snapshot \
      "$parked_quarantine" 2>/dev/null)" \
     && [[ "$parked_snapshot" == *$'\n'* ]]; then
    parked_mtime="${parked_snapshot%%$'\n'*}"
  fi
  if [[ "$parked_mtime" =~ ^[0-9]+$ ]]; then
    parked_age=$(( $(date +%s) - parked_mtime ))
  else
    parked_age=$(( max_age_seconds + 1 ))
  fi
  if (( parked_age >= 0 && parked_age <= max_age_seconds )) \
     && prompt_epoch_is_current; then
    # A concurrent gate may already have parked a newer FAIL at the stable name. In
    # that case the newer inode wins and only this selected older inode is discarded.
    if verdict_audit_link_no_clobber \
        "$parked_quarantine" "$prev_verdict_file" 2>/dev/null; then
      if prompt_epoch_is_current; then
        verdict_audit_unlink_if_identity \
          "$parked_quarantine" "$parked_identity" 2>/dev/null || true
        return 0
      fi
      verdict_audit_unlink_if_same_inode \
        "$prev_verdict_file" "$parked_quarantine" 2>/dev/null || true
    fi
  fi
  verdict_audit_unlink_if_identity \
    "$parked_quarantine" "$parked_identity" 2>/dev/null || true
  return 0
}
expire_stale_prev

# Resolve the exact turn before accepting any runtime artifact. A user steer may retain
# the harness turn id, while the content-derived FINAL_ID necessarily changes.
if ! prepare_audit_transcript; then
  block "Verdict gate could not publish a bounded final-turn transcript snapshot. Fix the session state path before ending."
fi
resolve_final_message
if [[ "$transcript_snapshot_truncated" == true ]]; then
  if [[ -z "$FINAL_TEXT" ]]; then
    FINAL_TEXT="Verdict evidence is incomplete because the final-turn snapshot exceeded its byte limit."
    FINAL_SOURCE="transcript"
    identify_final_message
  fi
  if [[ -z "$reentry_prompt_epoch" ]]; then
    log_decision extract truncated-block
    audit_before_stop \
      "Verdict gate requires an independent FAIL dossier because the final-turn evidence snapshot is incomplete or exceeded the ${transcript_turn_max_bytes}-byte limit. The auditor must not infer from omitted records."
  fi
fi
if [[ -z "$FINAL_TEXT" ]]; then
  if [[ "$transcript_had_content" == true ]]; then
    log_decision extract blind-allow
    allow_with_note "[verdict-gate] transcript has content but no assistant text after 2s → allowing UNJUDGED"
  else
    log_decision extract empty-allow
    allow
  fi
fi

# A session dossier has authority only while its request still names this exact turn and
# that generation has not been canceled. UserPromptSubmit revokes the request directly;
# INT/TERM has no prompt hook, so the runner publishes a generation-named tombstone. The
# Stop gate consumes that marker by retiring the exact request and dossier before issuing
# a fresh generation. Removing authority before the marker makes any later writer harmless.
request_is_current=false
if load_verdict_request true; then
  if [[ "$session_scope" != "-" ]]; then
    if verdict_audit_cancellation_exists "$audit_cancellation_file"; then
      log_decision cancellation discard-generation
      if consume_current_verdict_request >/dev/null 2>&1; then
        discard_matching_json_generation \
          "$verdict_file" "$audit_generation" >/dev/null 2>&1 || true
        discard_path_for_current_epoch "$last_uuid_file" >/dev/null 2>&1 || true
        discard_path_for_current_epoch "$payload_transcript_file" >/dev/null 2>&1 || true
        verdict_audit_clear_cancellation_records \
          "$audit_cancellation_file" >/dev/null 2>&1 || true
      fi
      request_is_current=false
    fi
  fi
elif [[ "$session_scope" != "-" ]]; then
  # Re-check before replacement in ensure_verdict_request(). A concurrent newer Stop
  # may have installed valid authority after this failed snapshot.
  :
fi

# ── Present dossier → validate the binding, then the verdict decides ─────────
# Rename first: every later consume/park/restore operation owns this exact inode. A
# canceled auditor may publish a newer dossier at the stable path while the gate
# is deciding; that newer pathname is never opened, moved, or deleted by this decision.
dossier_observed_identity=""
retire_selected_dossier() {
  [[ -n "${dossier_quarantine:-}" \
     && "$dossier_observed_identity" =~ ^[0-9]+:[0-9]+$ ]] || return 1
  verdict_audit_unlink_if_identity \
    "$dossier_quarantine" "$dossier_observed_identity" 2>/dev/null
}
if [[ "$request_is_current" == true \
   && ( -e "$verdict_file" || -L "$verdict_file" ) ]]; then
  dossier_observed_identity="$(verdict_audit_path_identity \
    "$verdict_file" 2>/dev/null)" || dossier_observed_identity=""
fi
if [[ "$request_is_current" == true && -n "$dossier_observed_identity" ]] \
   && start_decision_lease \
   && current_verdict_authority_matches; then
  dossier_quarantine="${verdict_file}.inspect-$$-${RANDOM:-0}"
  if verdict_audit_rename_no_clobber_exact \
      "$verdict_file" "$dossier_quarantine" 2>/dev/null; then
    if ! verdict_audit_selected_identity_matches \
        "$dossier_quarantine" "$dossier_observed_identity" 2>/dev/null; then
      verdict_audit_restore_no_clobber \
        "$dossier_quarantine" "$verdict_file" 2>/dev/null || true
    else
    dossier_file_snapshot=""
    verdict_json=""
    v_mtime=0
    if dossier_file_snapshot="$(verdict_audit_read_json_snapshot \
        "$dossier_quarantine" 2>/dev/null)" \
       && [[ "$dossier_file_snapshot" == *$'\n'* ]]; then
      v_mtime="${dossier_file_snapshot%%$'\n'*}"
      verdict_json="${dossier_file_snapshot#*$'\n'}"
    fi
    verdict_document="$(printf '%s' "$verdict_json" \
      | verdict_audit_normalize_dossier 2>/dev/null || true)"
    verdict_snapshot="$verdict_document"
    verdict_json="$verdict_document"
    # Parse the immutable in-memory JSON snapshot. JSON preserves an empty detached-HEAD
    # branch; Bash IFS whitespace transport does not.
    v_branch="$(printf '%s' "$verdict_snapshot" | jq -r '.branch // ""' 2>/dev/null || true)"
    v_head="$(printf '%s' "$verdict_snapshot" | jq -r '.head // ""' 2>/dev/null || true)"
    v_tree="$(printf '%s' "$verdict_snapshot" | jq -r '.tree_hash // ""' 2>/dev/null || true)"
    v_verdict="$(printf '%s' "$verdict_snapshot" | jq -r '.verdict // ""' 2>/dev/null || true)"
    v_generation="$(printf '%s' "$verdict_snapshot" | jq -r '.generation // ""' 2>/dev/null || true)"
    now_epoch="$(date +%s)"
    [[ "$v_mtime" =~ ^[0-9]+$ ]] || v_mtime=0
    age=$(( now_epoch - v_mtime ))
    cur_tree="$(compute_tree_hash)"

    generation_matches=false
    if [[ "$session_scope" == "-" ]]; then
      [[ -z "$v_generation" || "$v_generation" == "legacy" ]] && generation_matches=true
    elif [[ "$v_generation" == "$audit_generation" ]]; then
      generation_matches=true
    fi

    if [[ "$generation_matches" != true ]]; then
      log_decision dossier discard-generation
      retire_selected_dossier || true
    elif [[ "$v_branch" != "$branch" ]] || \
       [[ "$v_head" != "$head" ]] || \
       [[ "$v_tree" != "$cur_tree" ]] || \
       (( age < 0 || age > max_age_seconds )); then
      log_decision dossier discard-stale
      if ! consume_current_verdict_request; then
        retire_selected_dossier || true
        [[ "$session_scope" == "-" ]] || request_is_current=false
      elif [[ "$v_verdict" == "FAIL" ]] \
         && prompt_epoch_is_current \
         && (( age >= 0 && age <= max_age_seconds )); then
        # Exact rename cannot reinterpret a directory destination. Retain the dossier's
        # original freshness timestamp: refreshing it here would let an old result gain a
        # second authority window. On failure preserve the quarantine and fail closed.
        if verdict_audit_link_no_clobber \
            "$dossier_quarantine" "$prev_verdict_file" 2>/dev/null; then
          if prompt_epoch_is_current; then
            retire_selected_dossier || true
          else
            verdict_audit_unlink_if_same_inode \
              "$prev_verdict_file" "$dossier_quarantine" 2>/dev/null || true
            retire_selected_dossier || true
          fi
        else
          retire_selected_dossier || true
        fi
        [[ "$session_scope" == "-" ]] || request_is_current=false
      else
        retire_selected_dossier || true
        [[ "$session_scope" == "-" ]] || request_is_current=false
      fi
    else
      case "$v_verdict" in
        PASS)
          if consume_current_verdict_request; then
            log_decision dossier PASS-allow
            retire_selected_dossier || true
            discard_path_for_current_epoch "$prev_verdict_file" >/dev/null 2>&1 || true
            discard_path_for_current_epoch "$payload_transcript_file" >/dev/null 2>&1 || true
            allow
          fi
          log_decision dossier discard-revoked
          retire_selected_dossier || true
          [[ "$session_scope" == "-" ]] || request_is_current=false
          ;;
        IN_PROGRESS)
          remaining="$(printf '%s' "$verdict_json" \
            | jq -r '.findings[]? | "  - " + .' 2>/dev/null || echo '')"
          if consume_current_verdict_request; then
            log_decision dossier IN_PROGRESS-allow
            retire_selected_dossier || true
            discard_path_for_current_epoch "$prev_verdict_file" >/dev/null 2>&1 || true
            discard_path_for_current_epoch "$payload_transcript_file" >/dev/null 2>&1 || true
            allow_with_note "Verdict: IN_PROGRESS — proof deferred, work not yet complete:
${remaining}"
          fi
          log_decision dossier discard-revoked
          retire_selected_dossier || true
          [[ "$session_scope" == "-" ]] || request_is_current=false
          ;;
        *)
          if current_verdict_authority_matches; then
            log_decision dossier FAIL-block
            findings="$(printf '%s' "$verdict_json" \
              | jq -r '.findings[]? | "  - " + .' 2>/dev/null || echo '')"
            if ! prompt_epoch_is_current; then
              :
            elif ! verdict_audit_restore_no_clobber \
                "$dossier_quarantine" "$verdict_file" 2>/dev/null; then
              printf 'preflight-verdict-check: retained FAIL could not be restored from %s\n' \
                "$dossier_quarantine" >&2
            elif prompt_epoch_is_current; then
              # Legacy callers provide no session/message binding. Retaining their FAIL
              # would poison every later Stop, including unrelated chat. Session-scoped
              # callers keep the dossier so unchanged retries do not buy a new audit.
              [[ "$session_scope" != "-" ]] || rm -f "$verdict_file"
              block "Verdict proof check FAILED on branch '${branch}':

${findings}

Revise the user-facing answer to address each finding, then end the turn again; the
Stop gate will re-audit the revised answer automatically."
            else
              discard_matching_json_generation \
                "$verdict_file" "$audit_generation" >/dev/null 2>&1 || true
            fi
          fi
          log_decision dossier discard-revoked
          retire_selected_dossier || true
          request_is_current=false
          ;;
      esac
    fi
    fi
  fi
fi
stop_decision_lease

# ── An audit is RUNNING and has not answered yet → allow, don't busy-wait ────
# Level-triggered gate, edge-triggered remedy: an audit takes minutes, a re-block cycle
# ~3s, so without this rung the agent is re-blocked for the whole duration of the fix
# the gate demanded. Observed: 108 blocks in one session, 39 in a 512s window.
# Retained for transition/recovery: the current Stop path waits on its runner directly,
# but an older hook or manual headless invocation may already own the lock.
audit_in_flight() {
  # Dossier absence is the runner's own proof it has not answered (it removes the file
  # before auditing). Redundant with the call site below the dossier branch, kept so the
  # predicate survives being hoisted.
  [[ "$request_is_current" == true && -r "$audit_lock_file" && ! -e "$verdict_file" ]] \
    || return 1
  local record_snapshot body pid deadline lock_pgid lock_scope owner_token lock_generation
  local lock_start_token extra actual_start_token
  local lock_mtime now
  record_snapshot="$(verdict_audit_read_single_record_snapshot \
    "$audit_lock_file" 2>/dev/null)" || return 1
  [[ "$record_snapshot" == *$'\n'* ]] || return 1
  lock_mtime="${record_snapshot%%$'\n'*}"
  body="${record_snapshot#*$'\n'}"
  # Here-string, not `read < file`: the body has no trailing newline, so `read` assigns
  # and still exits 1 at EOF, which with `|| return 1` silently disables this rung.
  read -r pid deadline lock_pgid lock_scope owner_token lock_generation \
    lock_start_token extra <<< "$body"
  # `0` excluded: `kill -0 0` signals the caller's own process group and succeeds, so a
  # truncated write would buy a blanket allow. $$ is never 0.
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  if [[ "$session_scope" != "-" ]]; then
    [[ "$lock_pgid" =~ ^(0|[1-9][0-9]*)$ \
       && "$lock_scope" == "$session_scope" \
       && "$owner_token" =~ ^[1-9][0-9]*-[0-9]+-[0-9]+$ \
       && "$lock_generation" == "$audit_generation" \
       && ( -z "$lock_start_token" \
            || "$lock_start_token" =~ ^cksum-[0-9]+-[0-9]+$ ) \
       && -z "$extra" ]] || return 1
  fi
  # Metadata and PID liveness are observations, not ownership: SIGKILL can strand the
  # former and PID reuse can satisfy the latter. The runner's stable kernel lease is the
  # authoritative proof. If Perl/flock is unavailable or errors, fail closed to triage.
  [[ -e "$audit_mutex_file" ]] || return 1
  command -v perl >/dev/null 2>&1 || return 1
  perl -MFcntl=:DEFAULT,:flock -MErrno=EAGAIN,EWOULDBLOCK -e '
    my $path = shift;
    $SIG{ALRM} = sub { exit 2 };
    alarm 1;
    exit 2 if lstat($path) && -l _;
    my $flags = O_RDWR | O_NONBLOCK;
    $flags |= Fcntl::O_NOFOLLOW() if defined &Fcntl::O_NOFOLLOW;
    sysopen(my $fh, $path, $flags) or exit 2;
    my @opened = stat($fh);
    my @named = lstat($path);
    exit 2 unless @opened && @named && -f $fh && $opened[3] == 1
      && $opened[0] == $named[0] && $opened[1] == $named[1];
    my $locked = flock($fh, LOCK_EX | LOCK_NB);
    my $lock_errno = 0 + $!;
    @opened = stat($fh);
    @named = lstat($path);
    exit 2 unless @opened && @named && -f $fh && $opened[3] == 1
      && $opened[0] == $named[0] && $opened[1] == $named[1];
    exit 1 if $locked;
    alarm 0;
    $! = $lock_errno;
    exit(($!{EAGAIN} || $!{EWOULDBLOCK}) ? 0 : 2);
  ' "$audit_mutex_file" || return 1
  # A lock file alone proves nothing: the trap misses SIGKILL, orphaning the lock.
  kill -0 "$pid" 2>/dev/null || return 1
  if [[ -n "$lock_start_token" ]]; then
    actual_start_token="$(verdict_audit_process_start_token "$pid" 2>/dev/null)" \
      || return 1
    [[ "$actual_start_token" == "$lock_start_token" ]] || return 1
  fi
  now="$(date +%s)"
  [[ "$lock_mtime" =~ ^[0-9]+$ ]] || return 1
  (( lock_mtime <= now )) || return 1
  # Only the runner knows VERDICT_AUDITOR_TIMEOUT, so it writes the deadline; bounding
  # by max_age_seconds (dossier staleness) would expire the lock mid-run. Past the
  # ceiling is rejected, not capped — that lock is not what we think it is.
  if [[ -z "$deadline" ]]; then
    # No deadline field: a lock from an older runner. Fall back to the conservative
    # dossier-age bound rather than trusting an unbounded lease.
    (( now - lock_mtime >= 0 && now - lock_mtime <= max_age_seconds )) || return 1
  elif verdict_audit_epoch_is_bounded "$deadline"; then
    (( now <= deadline && deadline <= lock_mtime + audit_lock_max_seconds )) || return 1
  else
    # A present but malformed field is not legacy metadata. Fail closed before Bash can
    # wrap it or reinterpret a torn/hostile lease as a plausible live deadline.
    return 1
  fi
  return 0
}
if audit_in_flight; then
  log_decision audit inflight-allow
  allow
fi

# ── No (usable) dossier → triage: does the turn assert a verdict? ───────────
# Flush-race guard: if the newest transcript message is the one already judged, the
# harness fired Stop before appending this turn's final text. Wait briefly for the
# fresh message; if none arrives there is nothing new to judge → allow. A message
# is never judged twice. A payload-only message has nothing to flush: only Codex's
# active-hook signal plus an identical content identity proves that call is recursive.
recorded_id="$(verdict_audit_read_single_record "$last_uuid_file" 2>/dev/null || echo '')"
if [[ -n "$FINAL_ID" && -n "$recorded_id" && "$FINAL_ID" == "$recorded_id" ]]; then
  if [[ "$FINAL_SOURCE" == "payload" && "$stop_hook_active" == "true" ]]; then
    log_decision race stale-allow
    allow_with_note "[verdict-gate] Stop payload unchanged during active hook → allow"
  fi
  if [[ "$FINAL_SOURCE" == "transcript" ]]; then
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      sleep 0.2
      if [[ "$AUDIT_TRANSCRIPT_REFRESHABLE" == true ]]; then
        prepare_audit_transcript "$AUDIT_TRANSCRIPT_SOURCE_PATH" refresh \
          >/dev/null 2>&1 || true
      fi
      extract_final_message
      [[ "$FINAL_ID" != "$recorded_id" ]] && break
    done
    [[ -z "$FINAL_TEXT" ]] && use_payload_message
    if [[ -z "$FINAL_TEXT" || "$FINAL_ID" == "$recorded_id" ]]; then
      log_decision race stale-allow
      allow_with_note "[verdict-gate] transcript unchanged since last judgment → allow"
    fi
  fi
fi

# `stripped` stays the pattern tiers' text; only the classifier gets citations.
stripped="$(printf '%s\n' "$FINAL_TEXT" | strip_code_static)"
stripped_cited="$(printf '%s\n' "$FINAL_TEXT" | strip_code_cited)"
prompt_epoch_is_current || allow
mkdir -p "$(dirname "$last_uuid_file")" 2>/dev/null || true
publish_record_for_current_epoch "$last_uuid_file" "$FINAL_ID" || allow # judged now

# ── Tier A (0ms): harness text asserts nothing → allow without a model call ──
# Placed AFTER the identity write so this allow path records what it judged, exactly
# like every other one.
if is_harness_noise "$stripped"; then
  log_decision harness noise-allow
  allow_with_note "[verdict-gate] harness/API text only, no assistant claim → allow"
fi

# ── Tier B (0ms): assertion-only claim → block without a model call ──────────
# Only the forms that report an observation (see assertion_patterns). Everything the
# classifier is better at judging falls through to tier C untouched.
asserted="$(printf '%s\n' "$stripped" | grep -Eio "$assertion_patterns" 2>/dev/null | head -n1 || true)"
if [[ -n "$asserted" ]]; then
  log_decision assertion match-block
  audit_before_stop "This turn asserts a verdict (\"${asserted}\") but no audited
dossier backs it. A claim stated as established needs proof attached."
fi

classifier_bytes="$(LC_ALL=C printf '%s' "$stripped_cited" | wc -c | tr -d ' ')"
if (( classifier_bytes > classifier_max_bytes )); then
  log_decision triage oversized-block
  audit_before_stop "This turn is too large for classifier input
(${classifier_bytes} bytes; limit ${classifier_max_bytes}). Audit its file-backed
transcript before treating its conclusions as established."
fi

triage="$(should_audit "$stripped_cited")"
prompt_epoch_is_current || allow
if [[ "$triage" == "NO" ]]; then
  log_decision triage NO-allow
  allow_with_note "[verdict-gate] triage: NO — nothing taken on trust → allow"
fi
if [[ "$triage" == "YES" ]]; then
  log_decision triage YES-block
  audit_before_stop "This turn asserts a verdict (triage: YES) but no audited
dossier backs it. A claim stated as established needs proof attached."
fi

# Triage UNKNOWN (no model reachable) → deterministic pattern fallback.
matched="$(printf '%s\n' "$stripped" | grep -Eio "$verdict_patterns" 2>/dev/null | head -n1 || true)"
if [[ -z "$matched" ]]; then
  log_decision regex none-allow
  allow_with_note "[verdict-gate] triage unavailable, fallback patterns: no match → allow"
fi

log_decision regex match-block
audit_before_stop "This turn asserts a verdict (matched: \"${matched}\") but no audited
dossier backs it. A claim stated as established needs proof attached."
