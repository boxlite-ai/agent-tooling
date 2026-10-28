#!/usr/bin/env bash
# Bounded local execution diagnostics; no dossier authority. Source without effects.
audit_diagnostic_tail() {
  # Drain the stream even after the retained tail fills, so logging cannot block a child.
  perl -e '
    my $tail="";
    while (read(STDIN,my $chunk,4096)) { $tail.=$chunk; $tail=substr($tail,-8192); }
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
  '
}

audit_diagnostic_record() { # root scope gate generation attempt route start process-exit runner-exit outcome stderr-file
  local root="$1" scope="$2" gate="$3" generation="$4" attempt="$5" route="$6"
  local started="$7" process_exit="$8" runner_exit="$9" outcome="${10}" stderr_file="${11}"
  local tail="" elapsed record path
  elapsed="$(( $(date +%s) - started ))"; (( elapsed >= 0 )) || elapsed=0
  [[ -z "$stderr_file" || ! -f "$stderr_file" ]] || tail="$(audit_diagnostic_tail < "$stderr_file")"
  record="$(jq -nc --arg gate "$gate" --arg generation "$generation" --arg attempt "$attempt" \
    --arg route "$route" --arg outcome "$outcome" --arg tail "$tail" \
    --argjson elapsed "$elapsed" --argjson process "$process_exit" --argjson runner "$runner_exit" \
    '{gate:$gate,generation:$generation,attempt_id:$attempt,route:$route,outcome:$outcome,
      elapsed_seconds:$elapsed,process_exit:$process,runner_exit:$runner,stderr_tail:$tail}')" || return 1
  path="$(verdict_audit_state_path "$root/.agents/state/audit-diagnostics.jsonl" "$scope")"
  verdict_audit_append_log_line "$path" "$record" || return 1
  printf 'audit: route=%s process_exit=%s runner_exit=%s elapsed_seconds=%s outcome=%s; diagnostics=%s\n' \
    "$route" "$process_exit" "$runner_exit" "$elapsed" "$outcome" "$path" >&2
}
