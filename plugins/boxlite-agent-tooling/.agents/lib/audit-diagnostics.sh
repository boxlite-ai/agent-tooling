#!/usr/bin/env bash
# Bounded local execution diagnostics; no dossier authority. Source without effects.
audit_diagnostic_tail() {  # [abort indicator]
  # Drain the stream even after the retained tail fills, so logging cannot block a child.
  perl -MIO::Select -e '
    my ($abort) = @ARGV;
    my $input = length($abort) ? IO::Select->new(\*STDIN) : undef;
    binmode(STDIN, ":raw") if $input;
    my $tail="";
    while (1) {
      my $stopping = $input && -e $abort;
      if ($input && !$input->can_read($stopping ? 0 : 0.05)) {
        last if $stopping;
        next;
      }
      my $chunk;
      my $count = $input ? sysread(STDIN, $chunk, 4096) : read(STDIN, $chunk, 4096);
      last unless $count;
      $tail .= $chunk;
      $tail = substr($tail,-8192) if length($tail) > 8192;
      last if $stopping;
    }
    $tail =~ s/\e\[[0-?]*[ -\/]*[@-~]//g;
    $tail =~ s{([a-z][a-z0-9+.-]*://)[^\s/]+\@}{$1<redacted>\@}gi;
    $tail =~ s{((?:authorization\s*:\s*)?(?:bearer|basic)\s+)\S+}{$1<redacted>}gi;
    $tail =~ s{((?:api[_-]?key|access[_-]?token|token|secret|password)\s*[=:]\s*)[^\s,;]+}{$1<redacted>}gi;
    for my $key (keys %ENV) {
      next unless $key =~ /(?:TOKEN|SECRET|PASSWORD|API_KEY|PROXY)$/i;
      my $value=$ENV{$key}; next unless defined($value) && length($value)>=4;
      $tail =~ s/\Q$value\E/<redacted>/g;
    }
    $tail =~ s{[A-Za-z0-9_+=/.-]{24,}}{<redacted-token>}g;
    print substr($tail,-4096);
  ' "${1:-}"
}

# The optional 12th argument is the auditor settings object (design #474):
# {model, effort, model_source, observed, dropped_effort_env}.
audit_diagnostic_record() { # root scope gate generation attempt route start process-exit runner-exit outcome stderr-file [auditor-json]
  local root="$1" scope="$2" gate="$3" generation="$4" attempt="$5" route="$6"
  local started="$7" process_exit="$8" runner_exit="$9" outcome="${10}" stderr_file="${11}"
  local auditor="${12:-null}" tail="" elapsed record path settings=""
  elapsed="$(( $(date +%s) - started ))"; (( elapsed >= 0 )) || elapsed=0
  [[ -z "$stderr_file" || ! -f "$stderr_file" ]] || tail="$(audit_diagnostic_tail '' < "$stderr_file")"
  record="$(jq -nc --arg gate "$gate" --arg generation "$generation" --arg attempt "$attempt" \
    --arg route "$route" --arg outcome "$outcome" --arg tail "$tail" \
    --argjson elapsed "$elapsed" --argjson process "$process_exit" --argjson runner "$runner_exit" \
    --argjson auditor "$auditor" \
    '{gate:$gate,generation:$generation,attempt_id:$attempt,route:$route,outcome:$outcome,
      elapsed_seconds:$elapsed,process_exit:$process,runner_exit:$runner,stderr_tail:$tail}
     + if $auditor == null then {} else {auditor:$auditor} end')" || return 1
  path="$(verdict_audit_state_path "$root/.agents/state/audit-diagnostics.jsonl" "$scope")"
  verdict_audit_append_log_line "$path" "$record" || return 1
  [[ "$auditor" == null ]] || settings="$(jq -r '" model=\(.model) effort=\(.effort)"' <<<"$auditor")"
  printf 'audit: route=%s process_exit=%s runner_exit=%s elapsed_seconds=%s outcome=%s%s; diagnostics=%s\n' \
    "$route" "$process_exit" "$runner_exit" "$elapsed" "$outcome" "$settings" "$path" >&2
}

# Builds the settings object above from the loaded row and the caller's observations.
audit_diagnostic_auditor() { # model effort model-source observed dropped-effort-env
  jq -nc --arg model "$1" --arg effort "$2" --arg source "$3" --arg observed "$4" \
    --arg dropped "$5" \
    '{model:$model,effort:$effort,model_source:$source,observed:$observed}
     + if $dropped == "" then {} else {dropped_effort_env:$dropped} end'
}
