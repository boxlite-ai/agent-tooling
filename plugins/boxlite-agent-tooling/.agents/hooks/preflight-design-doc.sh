#!/usr/bin/env bash
# PreToolUse: verify the current design before editor or shell operations.
# Native tool names/denials: openai/codex codex-rs/hooks/src/events/pre_tool_use.rs:30-44.
set -uo pipefail
plugin_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
deny() {
  printf 'design-doc: %s\n' "$1" >&2
  exit 2
}
for dependency in jq perl git curl; do
  command -v "$dependency" >/dev/null 2>&1 || deny "required command missing: $dependency"
done
payload="$(head -c 1048577)"
(( ${#payload} <= 1048576 )) || deny 'tool input exceeds the inspection limit'
tool="$(jq -er '.tool_name | strings | select(length > 0)' <<<"$payload")" || deny 'invalid tool input'
case "$tool" in
  Bash|Write|Edit|MultiEdit|NotebookEdit|apply_patch) ;;
  *) deny 'unrecognized tool at the code-edit boundary' ;;
esac
cwd="$(jq -er --arg fallback "${CLAUDE_PROJECT_DIR:-$PWD}" \
  '.tool_input.workdir // .tool_input.cwd // .cwd // $fallback | strings | select(length > 0)' \
  <<<"$payload")" || deny 'invalid working directory'
[[ -d "$cwd" ]] || deny 'working directory is unavailable'

_design_doc_research_command() { # shell source; fixed research/registration grammar
  # Shell syntax is rejected before tokenization; parse_words never evaluates input.
  # Keep this allowlist small: e.g. rg --pre and git diff textconv execute code.
  printf '%s' "$1" | perl -MText::ParseWords=parse_line -e '
    local $/; my $source = <STDIN> // "";
    # Only single-quoted literal fields: no editor, body-file, substitution, or chain.
    exit 0 if $source =~ m{\Agh issue create --title \x27[^\x27]+\x27 --body \x27[^\x27]+\x27(?: --repo [A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)?\z}s;
    exit 1 if $source =~ /[\n\r\x00\$`<>;&|(){}\\]/;
    # Expansion runs after this hook and can manufacture executable flags.
    my $unquoted = $source;
    $unquoted =~ s/\x27[^\x27]*\x27|"[^"]*"//g;
    exit 1 if $unquoted =~ /[*?\[\]~^#]/;
    my @args = parse_line(qr/\s+/, 0, $source);
    exit 1 unless @args && !grep { !defined } @args;
    my $command = shift @args;
    if ($command eq "bash") {
      exit 0 if @args == 2 && $args[0] eq $ARGV[0] && $args[1] eq "check";
      exit 0 if @args == 3 && $args[0] eq $ARGV[0] && $args[1] eq "bind"
        && $args[2] =~ m{\Ahttps://[A-Za-z0-9./_-]+\z};
      exit 1;
    }
    exit 0 if $command eq "pwd" && (!@args || "@args" eq "-P");
    exit 0 if $command eq "gh" && "@args" =~ m{\Aissue view [1-9][0-9]*(?: --repo [A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)?\z};
    if ($command eq "git") {
      shift @args if @args && $args[0] eq "--no-pager";
      exit 0 if "@args" =~ /\Astatus(?: --short| --branch| --porcelain)*\z/;
      exit 0 if "@args" =~ /\Adiff --no-ext-diff --no-textconv(?: --stat| --name-only| --cached)*\z/;
      exit 0 if "@args" =~ /\Arev-parse (--show-toplevel|HEAD|--absolute-git-dir)\z/;
      exit 0 if "@args" =~ /\Alog --oneline -n [1-9][0-9]{0,2}\z/;
      exit 1;
    }
    exit 0 if $command eq "rg" && @args == 1 && $args[0] eq "--files";
    if ($command eq "rg") {
      shift @args if @args && $args[0] eq "-n";
      exit 0 if @args >= 2 && !grep { /^-/ } @args;
    }
    exit 0 if $command eq "ls" && !@args;
    if ($command =~ /\A(cat|head|tail|ls)\z/) {
      exit 1 if !@args || grep { $_ !~ m{\A[A-Za-z0-9_./ -]+\z} } @args;
      exit 0;
    }
    exit 1;
  ' "$plugin_root/scripts/design-doc.sh"
}

if [[ "$tool" == Bash ]]; then
  command="$(jq -er '.tool_input.command // .tool_input.cmd | strings' <<<"$payload")" || deny 'missing shell command'
  _design_doc_research_command "$command" && exit 0
fi
# shellcheck source=../lib/verdict-audit-state.sh
source "$plugin_root/.agents/lib/verdict-audit-state.sh" || deny 'state library unavailable'
# shellcheck source=../lib/reply-summary.sh
source "$plugin_root/.agents/lib/reply-summary.sh" || deny 'writing checks unavailable'
# shellcheck source=../lib/design-doc.sh
source "$plugin_root/.agents/lib/design-doc.sh" || deny 'document verifier unavailable'
if ! design_doc_binding check "$cwd" >/dev/null; then
  deny "Before writing code, create a concise 1–3 page design doc, then run:
bash \"$plugin_root/scripts/design-doc.sh\" bind <GitHub-issue/Notion/Linear-URL>
Research tools and the registration command remain available."
fi
