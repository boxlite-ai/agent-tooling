#!/usr/bin/env bash
# Probe privacy (#327, design #335): replay each host manifest's PreToolUse dispatch so
# missing wiring fails, and check what design agents may send.
set -uo pipefail
plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
git init -q "$scratch/repo"
# A host-only address: the generic address rule misses it, so only the git-email rule can deny it.
git -C "$scratch/repo" config user.email tester@localhost
export PLUGIN_ROOT="$plugin" CLAUDE_PLUGIN_ROOT="$plugin"
unset GIT_DIR GIT_WORK_TREE
pass=0 fail=0
check() { # agent type, tool, tool_input JSON, wanted allow|deny, description
  local agent="$1" tool="$2" input="$3" want="$4" description="$5" manifest hook status denied wired payload
  payload="$(jq -nc --arg agent "$agent" --arg tool "$tool" --argjson input "$input" \
    --arg cwd "$scratch/repo" '{hook_event_name:"PreToolUse", tool_name:$tool, tool_input:$input,
      cwd:$cwd} + if $agent == "" then {} else {agent_type:$agent} end')"
  for manifest in hooks.json codex-hooks.json generic-hooks.json; do
    denied=false wired=false
    while IFS= read -r hook; do
      wired=true status=0
      (cd "$scratch/repo" && printf '%s' "$payload" | bash -c "$hook" >/dev/null 2>&1) || status=$?
      [[ "$status" != 2 ]] || denied=true
    done < <(jq -r --arg tool "$tool" '.hooks.PreToolUse[] | select(.matcher as $m | $tool | test($m))
      | .hooks[].command | select(contains("audit-privacy.sh"))' "$plugin/hooks/$manifest")
    if [[ "$wired" == true && ( "$want:$denied" == deny:true || "$want:$denied" == allow:false ) ]]; then
      printf 'PASS %s: %s\n' "$manifest" "$description"; pass=$((pass+1))
    else
      printf 'FAIL %s: %s (wanted %s, wired=%s, denied=%s)\n' "$manifest" "$description" \
        "$want" "$wired" "$denied"; fail=$((fail+1))
    fi
  done
}
cmd() { jq -nc --arg command "$1" '{command:$command}'; }
url() { jq -nc --arg url "$1" '{url:$url, prompt:"Summarize"}'; }
query() { jq -nc --arg query "$1" '{query:$query}'; }

for agent in boxlite-agent-tooling:design-auditor boxlite-agent-tooling:design-advisor; do
  name="${agent##*:}"
  check "$agent" WebFetch "$(url 'https://api.openalex.org/works?search=x&mailto=a@example.org')" \
    deny "$name: a mailto URL"
  check "$agent" Bash "$(cmd "curl -s 'https://www.ebi.ac.uk/europepmc/webservices/rest/search?query=x&email=y'")" \
    deny "$name: an email= parameter"
  check "$agent" Bash "$(cmd "curl -s -X POST https://api.openalex.org/api-keys -d '{}'")" \
    deny "$name: a key request"
  check "$agent" Bash "$(cmd "curl -s -H 'From: x' 'https://export.arxiv.org/api/query?search_query=x'")" \
    deny "$name: a From header"
  check "$agent" Bash "$(cmd "curl -s 'https://api.github.com/search/repositories?q=tester@localhost'")" \
    deny "$name: the git email"
  check "$agent" WebSearch "$(query 'papers by person@example.org')" deny "$name: an address in a search"
  check "$agent" WebSearch "$(query 'crossref polite mailto')" allow "$name: a search about mailto"
  check "$agent" Bash "$(cmd 'grep -n mailto design.md')" allow "$name: a local command"
  check "$agent" Bash "$(cmd "curl -s 'https://export.arxiv.org/api/query?search_query=abs:LLM'")" \
    allow "$name: a plain probe"
  check "$agent" Bash "$(cmd 'git ls-remote git@github.com:boxlite-ai/agent-tooling.git')" \
    allow "$name: an SSH remote"
done
check general-purpose WebFetch "$(url 'https://api.openalex.org/works?mailto=a@example.org')" \
  allow 'another agent'
check '' WebFetch "$(url 'https://api.openalex.org/works?mailto=a@example.org')" allow 'the main agent'

printf '%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
