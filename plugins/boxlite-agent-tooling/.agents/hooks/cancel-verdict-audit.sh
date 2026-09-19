#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# UserPromptSubmit hook: revoke a verdict audit owned by this same session.
#
# The Stop hook launches run-verdict-audit.sh synchronously. This hook never signals a PID
# selected from workspace state: revoking the session's request makes the runner cancel
# its own process group and discard any dossier produced for the abandoned turn.
#
# Current Codex dispatches UserPromptSubmit at its external UserInput edge and records a
# Stop continuation internally without re-dispatching it. Claude documents this event as
# running before a submitted prompt is processed; live delivery while a synchronous Task
# is still running remains a host behavior to verify end-to-end. Silent no-op is deliberate
# for malformed or unscoped events. The hook must never become an arbitrary-PID signal
# primitive or prevent the newer prompt from entering the task.
set -uo pipefail

for required_command in jq perl shasum awk; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    printf 'cancel-verdict-audit.sh: required dependency not found: %s\n' \
      "$required_command" >&2
    exit 2
  fi
done

raw_payload="$(cat)"
payload="$(printf '%s' "$raw_payload" | jq -ecs '
  if length == 1 and (.[0] | type) == "object" then .[0] else empty end
' 2>/dev/null || true)"
if [[ -z "$payload" ]]; then
  printf 'cancel-verdict-audit.sh: expected exactly one JSON hook object.\n' >&2
  exit 1
fi
is_user_prompt_submit="$(printf '%s' "$payload" | jq -r '
  (.hook_event_name | type) == "string" and .hook_event_name == "UserPromptSubmit"
' 2>/dev/null || echo 'false')"
[[ "$is_user_prompt_submit" == "true" ]] || exit 0
session_field_state="$(printf '%s' "$payload" | jq -r '
  if has("session_id") | not then "absent"
  elif (.session_id | type) == "string" and (.session_id | length) > 0 then "valid"
  else "invalid"
  end
' 2>/dev/null || echo 'invalid')"
[[ "$session_field_state" == absent ]] && exit 0
if [[ "$session_field_state" != valid ]]; then
  printf 'cancel-verdict-audit.sh: session_id must be a non-empty string when present.\n' >&2
  exit 1
fi

project_dir="${CLAUDE_PROJECT_DIR:-$PWD}"
if ! repo_root="$(git -C "$project_dir" rev-parse --show-toplevel 2>/dev/null)"; then
  printf 'cancel-verdict-audit.sh: project directory is not a Git repository: %s\n' \
    "$project_dir" >&2
  exit 1
fi
project_dir="$(cd "$repo_root" && pwd -P)"
tooling_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
audit_state_lib="$tooling_root/.agents/lib/verdict-audit-state.sh"
if [[ ! -r "$audit_state_lib" ]]; then
  printf 'cancel-verdict-audit.sh: missing %s — cannot scope audit state.\n' \
    "$audit_state_lib" >&2
  exit 1
fi
# shellcheck source=../lib/verdict-audit-state.sh
source "$audit_state_lib"
wake_lib="$tooling_root/.agents/lib/hook-wake.sh"
if [[ ! -r "$wake_lib" ]]; then
  printf 'cancel-verdict-audit.sh: missing %s — cannot recognise internal wakes.\n' \
    "$wake_lib" >&2
  exit 1
fi
# shellcheck source=../lib/hook-wake.sh
source "$wake_lib"
# Never transport the session string through command substitution: it strips trailing
# newlines. The shared helper streams the raw JSON value directly into git hash-object.
if ! session_scope="$(verdict_audit_scope_from_hook_payload \
    "$payload" "$project_dir" 2>/dev/null)"; then
  printf 'cancel-verdict-audit.sh: could not derive the session audit scope.\n' >&2
  exit 1
fi

# Claude dispatches UserPromptSubmit for its own task notifications before appending them
# to the transcript, so an internal turn is authenticated from the payload itself, and
# anything not authenticated falls through as a real prompt. A background audit's
# completion arrives as a bare envelope naming its generation, which the control facade
# credits a bounded number of times. The auditor's 30-second escalation is an asyncRewake
# wake whose marker rides in the reminder after the envelope (.agents/lib/hook-wake.sh):
# the escalation stores only the nonce's hash and spends it once, so a missing, forged,
# reused, or expired marker is a real prompt. A valid queued wake remains internal after
# terminal or prompt state moves on.
prompt_text="$(printf '%s' "$payload" | jq -r '
  if (.prompt | type) == "string" then .prompt else "" end
')"
if [[ "$prompt_text" == '<task-notification>'$'\n'*$'\n</task-notification>' ]]; then
  completion_generation="$(printf '%s' "$prompt_text" | jq -Rer '
    capture("<task-id>(?<generation>[A-Za-z0-9][A-Za-z0-9._-]{0,127})</task-id>").generation
  ' 2>/dev/null || true)"
  if [[ "$completion_generation" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] \
     && CLAUDE_PROJECT_DIR="$project_dir" bash \
       "$tooling_root/.agents/hooks/auditor-control.sh" \
       consume-completion "$session_scope" "$completion_generation" \
       >/dev/null 2>&1; then
    exit 0
  fi
fi
if wake_nonce="$(hook_wake_marker "$prompt_text" auditor-wake)"; then
  wake_nonce_hash="$(printf '%s' "$wake_nonce" | shasum -a 256 | awk '{print $1}')"
  if CLAUDE_PROJECT_DIR="$project_dir" bash \
    "$tooling_root/.agents/hooks/auditor-control.sh" \
    consume-wake "$session_scope" "$wake_nonce_hash" >/dev/null 2>&1; then
    exit 0
  fi
fi

state_dir="$project_dir/.agents/state"
if ! mkdir -p "$state_dir" 2>/dev/null; then
  printf 'cancel-verdict-audit.sh: could not create runtime state directory.\n' >&2
  exit 2
fi
audit_request_file="$(verdict_audit_state_path "$state_dir/verdict-request" "$session_scope")"
audit_publish_mutex_file="${audit_request_file}.publish.mutex"
audit_decision_mutex_file="${audit_request_file}.decision.mutex"
audit_cancellation_prefix="$(verdict_audit_state_path \
  "$state_dir/verdict-canceled" "$session_scope")"
verdict_file="$(verdict_audit_state_path "$state_dir/last-verdict.json" "$session_scope")"
previous_verdict_file="$(verdict_audit_state_path "$state_dir/last-verdict.prev.json" "$session_scope")"
last_uuid_file="$(verdict_audit_state_path "$state_dir/verdict-last-uuid" "$session_scope")"
payload_transcript_file="$(verdict_audit_state_path "$state_dir/verdict-stop-message.jsonl" "$session_scope")"
prior_audit_input_file="$(verdict_audit_state_path "$state_dir/verdict-previous-dossier.json" "$session_scope")"
prompt_epoch_file="$(verdict_audit_state_path "$state_dir/verdict-prompt-epoch" "$session_scope")"
old_prompt_epoch="-"
if [[ -e "$prompt_epoch_file" || -L "$prompt_epoch_file" ]]; then
  # The repair path below already replaces unsafe epoch path types. Such state cannot
  # authorize an override selection, so carry an impossible old epoch into the control
  # transition rather than failing before the established cancellation repair runs.
  old_prompt_epoch="$(verdict_audit_read_single_record "$prompt_epoch_file" 2>/dev/null)" \
    || old_prompt_epoch="invalid"
fi

# Persist the steer before touching any mutex. A Stop invocation snapshots this token on
# entry and refuses every later authority mutation when it changes, so cancellation stays
# effective even if the decision-holder crashes or this hook must return after contention.
prompt_epoch="$$-$(date +%s)-${RANDOM:-0}"
prompt_epoch_written=true
if ! printf '%s\n' "$prompt_epoch" \
    | verdict_audit_write_atomic "$prompt_epoch_file" 2>/dev/null; then
  # A directory, FIFO, or symlink at the epoch pathname must not turn cancellation into
  # a point-in-time delete. Select that exact entry under a quarantine name, retry the
  # regular-file publication, and leave a non-empty quarantined directory untouched.
  # This is recoverable state repair, never recursive deletion.
  prompt_epoch_quarantine="${prompt_epoch_file}.unsafe-$$-${RANDOM:-0}"
  if verdict_audit_rename_exact \
      "$prompt_epoch_file" "$prompt_epoch_quarantine" 2>/dev/null \
     && printf '%s\n' "$prompt_epoch" \
          | verdict_audit_write_atomic "$prompt_epoch_file" 2>/dev/null; then
    rm -f "$prompt_epoch_quarantine" 2>/dev/null || true
    rmdir "$prompt_epoch_quarantine" 2>/dev/null || true
  else
    prompt_epoch_written=false
    if [[ -e "$prompt_epoch_quarantine" || -L "$prompt_epoch_quarantine" ]]; then
      verdict_audit_restore_no_clobber \
        "$prompt_epoch_quarantine" "$prompt_epoch_file" 2>/dev/null || true
    fi
  fi
fi

# Revoke visible authority before any fallible mutex operation. An unsafe gitignored
# mutex path must not leave a superseded request/PASS consumable; the serialized cleanup
# below closes the hidden-quarantine and late-publication races when the mutex is usable.
rm -f "$audit_request_file" "$previous_verdict_file" "$last_uuid_file" \
  "$payload_transcript_file" "$prior_audit_input_file" "$verdict_file"

# The short decision mutex orders UserPromptSubmit against a Stop gate that has hidden a
# dossier under a quarantine pathname. Once held, revoke first so the live runner wakes;
# then wait on its publication lease and clean again so neither a runner promotion nor
# a late out-of-band write can resurrect the abandoned generation. The entire operation lives
# in one Perl process so the decision lock remains held through both cleanup passes.
perl -MFcntl=:DEFAULT,:flock -e '
  my ($decision_path, $publish_path, $request, $previous, $last_uuid,
      $payload_transcript, $prior_input, $cancel_prefix, $verdict) = @ARGV;

  sub unlink_prefixed {
    my ($prefix) = @_;
    my $slash = rindex($prefix, "/");
    return if $slash < 0;
    my $directory = substr($prefix, 0, $slash);
    my $basename = substr($prefix, $slash + 1);
    if (opendir(my $dir, $directory)) {
      while (defined(my $entry = readdir($dir))) {
        next unless index($entry, $basename) == 0;
        unlink($directory . "/" . $entry);
      }
      closedir($dir);
    }
  }

  sub unlink_state {
    unlink($request, $previous, $last_uuid, $payload_transcript, $prior_input, $verdict);
    unlink_prefixed($prior_input . ".input-");
    unlink_prefixed($cancel_prefix . ".");
    unlink_prefixed($verdict . ".audit-");
  }

  sub open_mutex {
    my ($path) = @_;
    return if lstat($path) && -l _;
    my $flags = O_RDWR | O_CREAT | O_APPEND | O_NONBLOCK;
    $flags |= Fcntl::O_NOFOLLOW() if defined &Fcntl::O_NOFOLLOW;
    sysopen(my $fh, $path, $flags, 0600) or return;
    my @opened = stat($fh);
    my @named = lstat($path);
    return unless @opened && @named && -f $fh && $opened[3] == 1
      && $opened[0] == $named[0] && $opened[1] == $named[1];
    return $fh;
  }

  $SIG{ALRM} = sub { unlink_state(); exit 0 };
  alarm 3;
  my $decision = open_mutex($decision_path) or exit 2;
  flock($decision, LOCK_EX) or exit 2;
  my @decision_opened = stat($decision);
  my @decision_named = lstat($decision_path);
  exit 2 unless @decision_opened && @decision_named && $decision_opened[3] == 1
    && $decision_opened[0] == $decision_named[0]
    && $decision_opened[1] == $decision_named[1];

  unlink_state();
  # Once revocation is visible, timeout cleanup is safe while this decision mutex remains
  # held: no Stop gate can publish a hidden quarantine after the final cleanup pass.
  $SIG{ALRM} = sub { unlink_state(); exit 0 };
  my $publish = open_mutex($publish_path);
  if ($publish) {
    flock($publish, LOCK_EX) or do { unlink_state(); exit 2 };
    my @publish_opened = stat($publish);
    my @publish_named = lstat($publish_path);
    if (!@publish_opened || !@publish_named || !-f $publish
        || $publish_opened[3] != 1
        || $publish_opened[0] != $publish_named[0]
        || $publish_opened[1] != $publish_named[1]) {
      unlink_state();
      exit 2;
    }
  }
  unlink_state();
  alarm 0;
' "$audit_decision_mutex_file" "$audit_publish_mutex_file" \
  "$audit_request_file" "$previous_verdict_file" "$last_uuid_file" \
  "$payload_transcript_file" "$prior_audit_input_file" \
  "$audit_cancellation_prefix" "$verdict_file" \
  >/dev/null 2>&1 || {
    printf 'cancel-verdict-audit.sh: could not serialize audit cancellation.\n' >&2
    exit 1
  }
if [[ "$prompt_epoch_written" != true ]]; then
  printf 'cancel-verdict-audit.sh: could not record the session prompt epoch.\n' >&2
  # UserPromptSubmit exit 2 is the cross-host fail-closed outcome. If cancellation
  # cannot be made durable, the newer prompt must not enter while an older Stop can
  # still recreate authority after this cleanup pass.
  exit 2
fi

# The same UserPromptSubmit edge owns override activation and revocation. Keeping it in
# this hook (rather than a second matching hook) is required because Codex launches
# matching command hooks concurrently: only this process knows the exact old/new epoch
# pair that makes a late selection lose to terminal audit completion.
auditor_control="$tooling_root/.agents/hooks/auditor-control.sh"
if [[ ! -r "$auditor_control" ]]; then
  printf 'cancel-verdict-audit.sh: missing %s — cannot update auditor override state.\n' \
    "$auditor_control" >&2
  exit 2
fi
if ! auditor_control_output="$(printf '%s' "$payload" \
    | CLAUDE_PROJECT_DIR="$project_dir" bash "$auditor_control" \
        handle-prompt "$old_prompt_epoch" "$prompt_epoch" 2>/dev/null)"; then
  printf 'cancel-verdict-audit.sh: could not update auditor override state.\n' >&2
  exit 2
fi
[[ -z "$auditor_control_output" ]] || printf '%s\n' "$auditor_control_output"
exit 0
