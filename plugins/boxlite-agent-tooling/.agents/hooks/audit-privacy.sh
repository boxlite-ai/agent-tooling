#!/usr/bin/env bash
# PreToolUse: keep personal identifiers and key requests out of design audit and advice
# probes (#327, design #335). A seatbelt, not a boundary: shell expansion, encoding,
# `-d @file` and Codex's hosted WebSearch bypass it. Other agents and local commands pass.
# Like audit-deadline.sh, a missing dependency passes: the hook never blocks what it
# cannot judge.
set -uo pipefail
payload="$(head -c 1048577)"
[[ "$payload" == *design-a* || "$payload" == *'"default"'* ]] || exit 0
command -v jq >/dev/null 2>&1 && command -v perl >/dev/null 2>&1 || exit 0
lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd -P)" || exit 0
# shellcheck source=../lib/subagent-identity.sh
source "$lib/subagent-identity.sh" || exit 0
agent="$(subagent_identity_auditor "$payload")" || exit 0
case "$agent" in design-auditor|design-advisor) ;; *) exit 0 ;; esac

# WebSearch sends only a query, so only addresses count there; a search about `mailto` runs.
tool="$(jq -r '.tool_name // "" | strings' <<<"$payload" 2>/dev/null)" || exit 0
case "$tool" in
  WebFetch) field=url scope=request ;;
  WebSearch) field=query scope=addresses ;;
  Bash) field=command scope=request ;;
  *) exit 0 ;;
esac
text="$(jq -r --arg field "$field" '.tool_input[$field] // "" | strings' <<<"$payload" 2>/dev/null)" \
  || exit 0
cwd="$(jq -r '.cwd // "" | strings' <<<"$payload" 2>/dev/null)" || cwd=''
git_email="$(git -C "${cwd:-$PWD}" config user.email 2>/dev/null)" || git_email=''

status=0
reason="$(perl -e '
  my ($tool, $scope, $text, $email) = @ARGV;
  # Only a network call carries a request: a URL, or a network client as a command word.
  exit 0 if $tool eq "Bash" && $text !~ m{https?://}i
    && $text !~ m{(?:^|[\s;&|(])(?:curl|wget|https?|gh|nc|ncat)(?:\s|$)};
  if ($scope eq "request") {
    print("a mailto parameter"), exit 10 if $text =~ /mailto/i;
    print("an email= parameter"), exit 10 if $text =~ /email=/i;
    print("an \"email\" field"), exit 10 if $text =~ /"email"/i;
    print("an /api-keys request"), exit 10 if $text =~ m{/api-keys}i;
    print("a From: header"), exit 10 if $text =~ /\bFrom:/;
  }
  # An address, but not an SSH remote such as git@host:owner/repo.
  print("an email address"), exit 10
    if $text =~ /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}(?![A-Za-z0-9.-]*:)/;
  print("the local git email"), exit 10 if length($email) && index(lc($text), lc($email)) >= 0;
  exit 0;
' "$tool" "$scope" "$text" "$git_email")" || status=$?
(( status == 10 )) || exit 0
printf 'audit-privacy: design audit and advice probes carry no personal identifiers or key requests (#327); this %s call carries %s. Remove it and retry.\n' \
  "$tool" "$reason" >&2
exit 2
