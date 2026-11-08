#!/usr/bin/env bash
# Test-only inputs; test commands always exercise the production CLI.
audit_test_reflection() {
  jq '{context,reflection:{history_hash,
    failure_ids:[.attempts[] | select(.outcome.verdict | IN("FAIL","ERROR")) | .id],
    diagnosis:"runner output identifies an unavailable executable",
    previous_fixes_failed_because:"the first retry repeated the missing dependency",
    changed_approach:"check dependency availability before retrying",
    checks:[{command:"command -v auditor",expected:"executable path",observed:"path resolved",
      evidence:"fixture probe output"}],auditor_gaps:[]}}' "$1"
}

audit_test_submit_due() {
  [[ -f "$2" ]] || return 0
  if jq -e '[.attempts[] | select(.outcome.verdict | IN("FAIL","ERROR"))] | length >= 2' "$2" >/dev/null; then
    audit_test_reflection "$2" | bash "$1" submit "$2" >/dev/null
  fi
}

audit_test_assessment() {
  jq -c '{reflection_hash:.attempts[-1].reflection_hash,assessment:"sufficient",
    evidence:"fixture check output",auditor_assessment:"dependency diagnosis matches both runner errors"}' "$1"
}
