#!/usr/bin/env bash
# Shared complete-source checks and push formatting; callers own findings and snapshots.
# shellcheck disable=SC2154 # Callers supply kind and tooling_root; add_finding owns findings.

commit_push_check_subject() {
  local subject="$1" context="$2"
  local conventional='^[a-z]+(\([^)]+\))?:[[:space:]][^[:space:]].+'
  if [[ -z "$subject" ]]; then
    add_finding "$context: commit subject unavailable to local audit; use -m/--message, a readable -F/--file, or audit at push"
    return
  fi
  if (( ${#subject} > 72 )); then
    add_finding "$context: subject exceeds 72 characters"
  fi
  if [[ ! "$subject" =~ $conventional ]]; then
    add_finding "$context: subject is not Conventional Commit format"
  fi
}

commit_push_check_diff() {  # private raw audit snapshot
  local diff_file="$1"
  local openai_live_pattern="sk-"
  openai_live_pattern+="live"
  local slack_pattern="xox"
  slack_pattern+="[baprs]-"
  local github_pattern="ghp"
  github_pattern+="_[A-Za-z0-9_]{20,}"
  local private_key_pattern="-{5}BEGIN [A-Z0-9 ]*PRIVATE KEY-{5}"
  local aws_access_key_pattern="(AKIA|ASIA)[0-9A-Z]{16}"
  local authorization_pattern="[Aa]uthorization:[[:space:]]*([Bb]earer|[Bb]asic)[[:space:]]+[^[:space:]]+"
  local bearer_pattern="[Bb]earer[[:space:]]+[A-Za-z0-9._~+/=-]{10,}"
  local secret_pattern="(${openai_live_pattern}|${slack_pattern}|${github_pattern}|${private_key_pattern}|${aws_access_key_pattern}|${authorization_pattern}|${bearer_pattern})"
  if [[ ! -s "$diff_file" ]]; then
    add_finding "Verify: no diff found for ${kind}"
    return
  fi
  if grep -qE "(^|\\+).*${secret_pattern}" "$diff_file"; then
    add_finding "Security: diff appears to contain a secret-like token"
  fi
  if grep -qE '^diff --git a/.*\.pr-reviewed\.json b/.*\.pr-reviewed\.json$' \
      "$diff_file"; then
    add_finding "Cross-cutting: PR review gate marker must not be committed"
  fi
}

commit_push_redact_text() {
  awk '
    BEGIN {
      secret_key = "([Ss][Ee][Cc][Rr][Ee][Tt]|[Tt][Oo][Kk][Ee][Nn]|[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]|[Cc][Rr][Ee][Dd][Ee][Nn][Tt][Ii][Aa][Ll]|[Aa][Pp][Ii][_-]?[Kk][Ee][Yy]|[Dd][Aa][Tt][Aa][Bb][Aa][Ss][Ee][_-]?[Uu][Rr][Ll]|[Dd][Ss][Nn]|[Cc][Oo][Nn][Nn][Ee][Cc][Tt][Ii][Oo][Nn][_-]?[Ss][Tt][Rr][Ii][Nn][Gg])"
      secret_sep = "[A-Za-z0-9_ -]*[[:space:]]*[:=][[:space:]]*"
    }
    {
      is_diff_path = ($0 ~ /^diff --git / ||
        $0 ~ /^--- (a\/|\/dev\/null|\")/ ||
        $0 ~ /^\+\+\+ (b\/|\/dev\/null|\")/ ||
        $0 ~ /^(rename|copy) (from|to) / ||
        $0 ~ /^Binary files /)
      gsub(/[A-Za-z][A-Za-z0-9+.-]*:\/\/[^[:space:]\"<>]*:[^[:space:]\"<>@]*@/, "<redacted@url@credentials>@")
      gsub(/[Aa][Uu][Tt][Hh][Oo][Rr][Ii][Zz][Aa][Tt][Ii][Oo][Nn]:[[:space:]]*([Bb][Ee][Aa][Rr][Ee][Rr]|[Bb][Aa][Ss][Ii][Cc])[[:space:]]+[^[:space:]\"<>]+/, "Authorization: <redacted-authorization>")
      gsub(/[Bb][Ee][Aa][Rr][Ee][Rr][[:space:]]+[A-Za-z0-9._~+\/=-]{10,}/, "Bearer <redacted-token>")
      gsub(/[?&][Aa][Cc][Cc][Ee][Ss][Ss][_-]?[Tt][Oo][Kk][Ee][Nn]=[^&[:space:]\"<>]+/, "<redacted-query-secret>")
      gsub(/[?&][Tt][Oo][Kk][Ee][Nn]=[^&[:space:]\"<>]+/, "<redacted-query-secret>")
      gsub(/[?&][Aa][Pp][Ii][_-]?[Kk][Ee][Yy]=[^&[:space:]\"<>]+/, "<redacted-query-secret>")
      gsub(/[?&][Cc][Ll][Ii][Ee][Nn][Tt][_-]?[Ss][Ee][Cc][Rr][Ee][Tt]=[^&[:space:]\"<>]+/, "<redacted-query-secret>")
      gsub(/[?&][Ss][Ee][Cc][Rr][Ee][Tt]=[^&[:space:]\"<>]+/, "<redacted-query-secret>")
      gsub(/[?&][Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]=[^&[:space:]\"<>]+/, "<redacted-query-secret>")
      if (!is_diff_path)
        gsub(/[A-Za-z0-9_\/+=.-]{24,}/, "<redacted-token>")
      gsub(/-{5}BEGIN [A-Z0-9 ]*PRIVATE KEY-{5}/, "<redacted-private-key-boundary>")
      gsub(/-{5}END [A-Z0-9 ]*PRIVATE KEY-{5}/, "<redacted-private-key-boundary>")
      gsub(/(AKIA|ASIA)[0-9A-Z]{16}/, "<redacted-aws-access-key-id>")
      gsub(secret_key secret_sep "\"[^\"]*\"", "<redacted-secret-assignment>")
      gsub(secret_key secret_sep "\047[^\047]*\047", "<redacted-secret-assignment>")
      gsub(secret_key secret_sep "[^,;[:space:]]+", "<redacted-secret-assignment>")
      gsub(/<redacted@url@credentials>/, "<redacted-url-credentials>")
    }
    { print }
  '
}

commit_push_redact_diff() {
  commit_push_redact_text
}

commit_push_render_evidence() {  # exact raw push snapshot
  local raw_source_file="$1" instruction
  instruction="$(subagent_prompt audit/commit-push-context "$tooling_root")" || return 1
  printf '%s\n\n' "$instruction"
  printf '## Commit subjects in the exact pre-push ref-update context as JSON strings\n'
  sed -n 's/^commit-subject [0-9a-f][0-9a-f]* //p' "$raw_source_file" \
    | commit_push_redact_text | jq -R . | jq -s .
  printf '\n## Sanitized pre-push ref-update diff\n'
  commit_push_redact_diff < "$raw_source_file"
}
