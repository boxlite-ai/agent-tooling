#!/usr/bin/env bash
# One plugin, three hosts — and nothing that keeps them equal except this file.
#
# Claude Code discovers assets by CONVENTION (skills/, agents/, hooks/hooks.json at
# the plugin root), Codex by DECLARATION (.codex-plugin/plugin.json keys), Copilot by
# the generic plugin.json. Those are three independent resolution paths onto what must
# be one asset set, so every parity failure here is silent by construction: each host
# loads whatever its own path finds and has no way to notice the others found more.
# That already happened once — 2b56fc0 shipped 0.1.3 manifests while both versioned
# marketplaces kept advertising 0.1.2, and nothing said so.
#
# What is pinned, and why:
#
#   - The three plugin manifests agree on name/version/description, and the
#     marketplaces advertise the version that actually ships. Versions here are not
#     cosmetic: consumers pin installations by them.
#   - Codex's declared skills/hooks paths resolve to the SAME files Claude Code's
#     conventions discover, through the symlinks AGENTS.md prescribes
#     (skills -> .agents/skills, agents -> .claude/agents).
#   - Claude and Codex hook manifests stay behaviorally identical except for their
#     background-delivery primitive: Claude uses asyncRewake so a 30-second escalation
#     wakes the model, while Codex uses async because its strict schema does not accept
#     asyncRewake. Unknown keys still make Codex silently load no hooks at all.
#   - …and except for events Codex has no concept of. Codex's hook-event set is CLOSED,
#     so a Claude-only event in the Codex twin is not an ignored entry — it is an
#     unknown key, which costs every Codex gate at once. Those events are declared in
#     CLAUDE_ONLY_EVENTS, wired only in hooks/hooks.json, and excluded from the twin
#     comparison. Byte-equal twins were the right invariant while every event existed
#     on both hosts; the moment one does not, enforcing equality is what breaks Codex.
#   - Every wired command resolves the plugin root as ${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT}}
#     — Codex exports the first name, Claude Code the second. A bare single-host
#     variable expands empty on the other host and the hook runs /nonexistent.
#   - Agent specs resolve on every route: Claude Code prefixes the frontmatter `name`
#     with the plugin name, while Codex gets a schema-safe task name plus the exact
#     spec path (subagent.sh doctrine). A rename can strand either host silently.
#   - .codex-plugin/plugin.json declares NO agents key — deliberately. Codex's
#     collaboration.spawn_agent takes no spec parameter; the spec travels by path in
#     the message. Adding the key to "fix the asymmetry" hands a strictly-validating
#     parser an unknown key, and this repository has already paid to learn how that
#     ends. If Codex ever grows agent registration, update this pin consciously.
#
# Run with:  bash plugins/boxlite-agent-tooling/host-parity.test.sh
# Exits non-zero on any failure.
set -uo pipefail

PLUGIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$PLUGIN/../.." && pwd)"
GENERIC="$PLUGIN/plugin.json"
CLAUDE="$PLUGIN/.claude-plugin/plugin.json"
CODEX="$PLUGIN/.codex-plugin/plugin.json"
CLAUDE_HOOKS="$PLUGIN/hooks/hooks.json"
CODEX_HOOKS="$PLUGIN/hooks/codex-hooks.json"
CLAUDE_MKT="$REPO_ROOT/.claude-plugin/marketplace.json"
CODEX_MKT="$REPO_ROOT/.agents/plugins/marketplace.json"
COPILOT_MKT="$REPO_ROOT/.github/plugin/marketplace.json"
CLAUDE_SETTINGS="$REPO_ROOT/.claude/settings.json"
COPILOT_SETTINGS="$REPO_ROOT/.github/copilot/settings.json"

pass=0
fail=0
# Increment pass counter and print a PASS line.  # $1 = test name
ok()  { pass=$((pass + 1)); printf '  PASS  %s\n' "$1"; }
# Increment fail counter and print a FAIL line.  # $1 = test name
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }

command -v jq >/dev/null 2>&1 || { printf 'jq is required to run these tests\n' >&2; exit 2; }

# Directories resolved through `cd`, not realpath -m: a dangling symlink or a typo'd
# path must FAIL here, never normalise into a plausible-looking string.
# Resolve a directory to its canonical path, failing on dangling symlinks or typos.  # $1 = directory path; echoes canonical path or fails
resolve_dir() { (cd "$1" 2>/dev/null && pwd -P); }
# Resolve a file to its canonical path, failing if it does not exist.  # $1 = file path; echoes canonical path or fails
resolve_file() {
  local dir base
  dir="$(dirname "$1")"; base="$(basename "$1")"
  dir="$(resolve_dir "$dir")" || return 1
  [ -f "$dir/$base" ] || return 1
  printf '%s/%s\n' "$dir" "$base"
}

echo "## One plugin, three manifests — same identity"
for f in "$GENERIC" "$CLAUDE" "$CODEX"; do
  jq -e . "$f" >/dev/null 2>&1 && ok "valid JSON: ${f#"$PLUGIN"/}" \
                                || bad "valid JSON: ${f#"$PLUGIN"/}"
done
for key in name version description; do
  g="$(jq -r ".$key" "$GENERIC")"
  c="$(jq -r ".$key" "$CLAUDE")"
  x="$(jq -r ".$key" "$CODEX")"
  if [ "$g" = "$c" ] && [ "$g" = "$x" ] && [ -n "$g" ] && [ "$g" != "null" ]; then
    ok "same $key everywhere ($g)"
  else
    bad "same $key everywhere (generic: $g, claude: $c, codex: $x)"
  fi
done
VERSION="$(jq -r .version "$GENERIC")"

echo
echo "## Marketplaces advertise the plugin that actually ships"
# The Codex marketplace pins no version, so only the other two can drift — and both
# fields have moved in lockstep with the manifests on every release so far.
# Verify a marketplace file has version and metadata matching the plugin manifest.  # $1 = label (for test output), $2 = marketplace file path; reads VERSION, GENERIC, PLUGIN
check_versioned_marketplace() {  # <label> <file>
  local label="$1" file="$2" v
  for path in '.metadata.version' '.plugins[0].version'; do
    v="$(jq -r "$path" "$file")"
    [ "$v" = "$VERSION" ] && ok "$label: $path is $VERSION" \
                          || bad "$label: $path is $VERSION (got: $v)"
  done
  v="$(jq -r '.plugins[0].name' "$file")"
  [ "$v" = "$(jq -r .name "$GENERIC")" ] && ok "$label: entry names the plugin" \
                                         || bad "$label: entry names the plugin (got: $v)"
  v="$(jq -r '.plugins[0].description' "$file")"
  [ "$v" = "$(jq -r .description "$GENERIC")" ] && ok "$label: entry description matches the manifest" \
                                                || bad "$label: entry description matches the manifest"
  v="$(resolve_dir "$REPO_ROOT/$(jq -r '.plugins[0].source' "$file")")"
  [ "$v" = "$PLUGIN" ] && ok "$label: source resolves to the plugin" \
                       || bad "$label: source resolves to the plugin (got: $v)"
}
check_versioned_marketplace "claude"  "$CLAUDE_MKT"
check_versioned_marketplace "copilot" "$COPILOT_MKT"
v="$(jq -r '.plugins[0].name' "$CODEX_MKT")"
[ "$v" = "$(jq -r .name "$GENERIC")" ] && ok "codex: entry names the plugin" \
                                       || bad "codex: entry names the plugin (got: $v)"
jq -e '
  .plugins[0].source.source == "git-subdir" and
  .plugins[0].source.url == "https://github.com/boxlite-ai/agent-tooling.git" and
  .plugins[0].source.ref == "main" and
  .plugins[0].source.path == "./plugins/boxlite-agent-tooling" and
  .plugins[0].policy.installation == "INSTALLED_BY_DEFAULT" and
  .plugins[0].policy.authentication == "ON_INSTALL" and
  .plugins[0].category == "Developer Tools"
' "$CODEX_MKT" >/dev/null 2>&1 \
  && ok "codex: typed Git source and required install metadata" \
  || bad "codex: typed Git source and required install metadata"
v="$(resolve_dir "$REPO_ROOT/$(jq -r '.plugins[0].source.path' "$CODEX_MKT")")"
[ "$v" = "$PLUGIN" ] && ok "codex: source resolves to the plugin" \
                     || bad "codex: source resolves to the plugin (got: $v)"

echo
echo "## Consumer activation settings use typed GitHub marketplace sources"
for pair in "claude:$CLAUDE_SETTINGS" "copilot:$COPILOT_SETTINGS"; do
  label="${pair%%:*}"; settings="${pair#*:}"
  jq -e '
    .extraKnownMarketplaces["boxlite-agent-tooling"].source.source == "github" and
    .extraKnownMarketplaces["boxlite-agent-tooling"].source.repo == "boxlite-ai/agent-tooling" and
    .extraKnownMarketplaces["boxlite-agent-tooling"].source.ref == "main" and
    .enabledPlugins["boxlite-agent-tooling@boxlite-agent-tooling"] == true
  ' "$settings" >/dev/null 2>&1 \
    && ok "$label: typed GitHub activation source" \
    || bad "$label: typed GitHub activation source"
done

echo
echo "## Every host reaches the same skills tree"
# AGENTS.md: hosts point manifests at the symlink names, never at copies.
[ "$(readlink "$PLUGIN/skills")" = ".agents/skills" ] \
  && ok "skills is a symlink to .agents/skills" \
  || bad "skills is a symlink to .agents/skills (got: $(readlink "$PLUGIN/skills" || echo 'not a symlink'))"
canonical_skills="$(resolve_dir "$PLUGIN/.agents/skills")"
for pair in "generic:$(jq -r .skills "$GENERIC")" "codex:$(jq -r .skills "$CODEX")"; do
  label="${pair%%:*}"; declared="${pair#*:}"
  got="$(resolve_dir "$PLUGIN/$declared")"
  [ "$got" = "$canonical_skills" ] && ok "$label manifest skills resolve to .agents/skills" \
                                   || bad "$label manifest skills resolve to .agents/skills (got: ${got:-unresolvable})"
done
# Claude Code takes the conventional root directory the symlink provides.
[ "$(resolve_dir "$PLUGIN/skills")" = "$canonical_skills" ] \
  && ok "claude convention skills/ resolves to .agents/skills" \
  || bad "claude convention skills/ resolves to .agents/skills"
found=0
for skill_dir in "$PLUGIN"/.agents/skills/*/; do
  [ -d "$skill_dir" ] || continue
  found=$((found + 1))
  skill_file="$skill_dir/SKILL.md"
  skill_name="$(basename "$skill_dir")"
  if [ -f "$skill_file" ]; then
    ok "skill has SKILL.md: $skill_name"
    skill_bytes="$(wc -c < "$skill_file" | tr -d ' ')"
    [ "$skill_bytes" -le 6144 ] && ok "skill body stays below the selected-body cap: $skill_name ($skill_bytes bytes)" \
                                  || bad "skill body exceeds 6144 bytes: $skill_name ($skill_bytes bytes)"
    skill_description="$(awk 'BEGIN{fm=0} NR==1 && /^---$/{fm=1; next} fm==1 && /^---$/{exit} fm==1 && /^description:/{sub(/^description:[[:space:]]*/, ""); print; exit}' "$skill_file")"
    if [[ "$skill_description" == ">" || "$skill_description" == "|" ]]; then
      bad "skill catalog description is a budgeted single line: $skill_name"
    else
      ok "skill catalog description is a budgeted single line: $skill_name"
    fi
    [ "${#skill_description}" -le 96 ] && ok "skill catalog description stays below the host clipping budget: $skill_name (${#skill_description} chars)" \
                                          || bad "skill catalog description exceeds 96 chars: $skill_name (${#skill_description} chars)"
  else
    bad "skill has SKILL.md: $skill_name"
  fi
done
[ "$found" -gt 0 ] && ok "skills tree is not empty ($found skills)" \
                   || bad "skills tree is not empty"

echo
echo "## Every host reaches the same agent specs"
[ "$(readlink "$PLUGIN/agents")" = ".claude/agents" ] \
  && ok "agents is a symlink to .claude/agents" \
  || bad "agents is a symlink to .claude/agents (got: $(readlink "$PLUGIN/agents" || echo 'not a symlink'))"
canonical_agents="$(resolve_dir "$PLUGIN/.claude/agents")"
got="$(resolve_dir "$PLUGIN/$(jq -r .agents "$GENERIC")")"
[ "$got" = "$canonical_agents" ] && ok "generic manifest agents resolve to .claude/agents" \
                                 || bad "generic manifest agents resolve to .claude/agents (got: ${got:-unresolvable})"
found=0
for spec in "$PLUGIN"/.claude/agents/*.md; do
  [ -f "$spec" ] || continue
  found=$((found + 1))
  stem="$(basename "$spec" .md)"
  fm_name="$(awk 'BEGIN{fm=0} NR==1 && /^---$/{fm=1; next} fm==1 && /^---$/{exit} fm==1 && /^name:/{sub(/^name:[[:space:]]*/, ""); print; exit}' "$spec")"
  [ "$fm_name" = "$stem" ] && ok "spec name matches filename: $stem" \
                           || bad "spec name matches filename: $stem (frontmatter says: ${fm_name:-nothing})"
  spec_description="$(awk 'BEGIN{fm=0} NR==1 && /^---$/{fm=1; next} fm==1 && /^---$/{exit} fm==1 && /^description:/{sub(/^description:[[:space:]]*/, ""); print; exit}' "$spec")"
  if [[ "$spec_description" != ">" && "$spec_description" != "|" \
     && "${#spec_description}" -le 180 ]]; then
    ok "agent catalog description is concise: $stem (${#spec_description} chars)"
  else
    bad "agent catalog description must be one line and <=180 chars: $stem"
  fi
  spec_bytes="$(wc -c < "$spec" | tr -d ' ')"
  [ "$spec_bytes" -le 6144 ] && ok "agent spec is lazy and compact: $stem ($spec_bytes bytes)" \
                                || bad "agent spec exceeds 6144 bytes: $stem ($spec_bytes bytes)"
  if grep -Eq 'CLAUDE\.md:[0-9]' "$spec"; then
    bad "agent spec avoids brittle CLAUDE.md line references: $stem"
  else
    ok "agent spec avoids brittle CLAUDE.md line references: $stem"
  fi
done
[ "$found" -gt 0 ] && ok "agent specs exist ($found specs)" \
                   || bad "agent specs exist"
known_auditors="$("$PLUGIN/.agents/hooks/auditor-control.sh" --known-auditors 2>/dev/null | sort)"
shipped_auditors="$(find "$PLUGIN/.claude/agents" -maxdepth 1 -name '*-auditor.md' \
  -exec basename {} .md \; | sort)"
[ "$known_auditors" = "$shipped_auditors" ] \
  && ok "every shipped auditor has override control mapping" \
  || bad "every shipped auditor has override control mapping (known: ${known_auditors:-none})"
# The deliberate asymmetry, pinned so nobody "fixes" it into a silent Codex failure.
jq -e 'has("agents") | not' "$CODEX" >/dev/null 2>&1 \
  && ok "codex manifest declares no agents key (specs travel by path — see header)" \
  || bad "codex manifest declares no agents key (specs travel by path — see header)"

plugin_name="$(jq -r .name "$CLAUDE")"
routing="$(
  # shellcheck source=/dev/null
  source "$PLUGIN/.agents/lib/subagent.sh"
  subagent_instruction --agent verdict-auditor --root "$PLUGIN" --task audit
)"
case "$routing" in
  *"Task(subagent_type=\"$plugin_name:verdict-auditor\""*)
    ok "claude route scopes the agent with the manifest name" ;;
  *) bad "claude route scopes the agent with the manifest name" ;;
esac
case "$routing" in
  *'fork_turns="none"'*) ok "codex auditors start without cloning parent history" ;;
  *) bad "codex auditors start without cloning parent history" ;;
esac

for prompt in "$PLUGIN"/.agents/prompts/*.md; do
  prompt_bytes="$(wc -c < "$prompt" | tr -d ' ')"
  [ "$prompt_bytes" -le 2048 ] && ok "agent prompt is compact: $(basename "$prompt") ($prompt_bytes bytes)" \
                                  || bad "agent prompt exceeds 2048 bytes: $(basename "$prompt") ($prompt_bytes bytes)"
done
grep -q 'Spawn subagents' "$PLUGIN/.agents/prompts/commit-push-runner.md" \
  && bad "commit audit does not multiply into unconditional reviewers" \
  || ok "commit audit does not multiply into unconditional reviewers"
case "$routing" in
  *'task_name="verdict_auditor"'*"$PLUGIN/.claude/agents/verdict-auditor.md"*)
    ok "codex route normalizes task_name but preserves the spec path" ;;
  *) bad "codex route normalizes task_name but preserves the spec path" ;;
esac

echo
echo "## Host hooks differ only at the background-delivery boundary"
claude_hooks_file="$(resolve_file "$CLAUDE_HOOKS")"
[ -n "$claude_hooks_file" ] && ok "conventional hooks/hooks.json exists (claude discovery)" \
                            || bad "conventional hooks/hooks.json exists (claude discovery)"
codex_hooks_file="$(resolve_file "$CODEX_HOOKS")"
[ -n "$codex_hooks_file" ] && ok "codex hooks file exists" \
                           || bad "codex hooks file exists"
for pair in "generic:$(jq -r .hooks "$GENERIC")" "codex:$(jq -r .hooks "$CODEX")"; do
  label="${pair%%:*}"; declared="${pair#*:}"
  got="$(resolve_file "$PLUGIN/$declared")"
  [ "$got" = "$codex_hooks_file" ] && ok "$label manifest hooks resolve to hooks/codex-hooks.json" \
                                   || bad "$label manifest hooks resolve to hooks/codex-hooks.json (got: ${got:-unresolvable})"
done
for pair in "claude:$CLAUDE_HOOKS:asyncRewake" "codex:$CODEX_HOOKS:async"; do
  label="${pair%%:*}"; rest="${pair#*:}"; file="${rest%%:*}"; async_key="${rest##*:}"
  jq -e . "$file" >/dev/null 2>&1 && ok "$label: valid JSON" || bad "$label: valid JSON"
  unknown="$(jq -r --arg async_key "$async_key" '
    [ (keys_unsorted[] | select(. != "hooks")),
      (.hooks | keys_unsorted[] | select(test("^[A-Z][A-Za-z]*$") | not)),
      (.hooks[][] | keys_unsorted[] | select(IN("hooks","matcher") | not)),
      (.hooks[][].hooks[] | keys_unsorted[]
         | select(IN("type","command","statusMessage","timeout",$async_key) | not))
    ] | join(",")' "$file" 2>/dev/null)"
  [ -z "$unknown" ] && ok "$label: no unknown keys at any depth" \
                    || bad "$label: no unknown keys at any depth (found: $unknown)"
  flattened="$(jq -r '[.hooks[][] | select((.hooks | type) != "array" or (.hooks | length) == 0)] | length' "$file")"
  [ "$flattened" = "0" ] && ok "$label: every event entry nests a non-empty hooks array" \
                         || bad "$label: every event entry nests a non-empty hooks array ($flattened flat entries)"
  nontype="$(jq -r '[.hooks[][].hooks[] | select(.type != "command")] | length' "$file")"
  [ "$nontype" = "0" ] && ok "$label: every hook object is type command" \
                       || bad "$label: every hook object is type command ($nontype are not)"
done
# Codex's hook-event set is closed (HookEventsToml in the shipped binary). Held here as
# data so a newly wired event is checked against it without needing a Codex install:
# getting this wrong does not disable one hook, it disables all of them.
CODEX_EVENTS='PreToolUse PermissionRequest PostToolUse PreCompact PostCompact
SessionStart SessionEnd UserPromptSubmit SubagentStart SubagentStop Stop Interrupt'
# Events Claude Code has and Codex does not. Wired only in hooks/hooks.json.
CLAUDE_ONLY_EVENTS='StopFailure'

for event in $CLAUDE_ONLY_EVENTS; do
  case " $(echo $CODEX_EVENTS) " in
    *" $event "*) bad "claude-only event is genuinely absent from Codex: $event" ;;
    *)            ok  "claude-only event is genuinely absent from Codex: $event" ;;
  esac
done
for event in $(jq -r '.hooks | keys_unsorted[]' "$CODEX_HOOKS"); do
  case " $(echo $CODEX_EVENTS) " in
    *" $event "*) ok  "codex manifest event is in Codex's closed set: $event" ;;
    *)            bad "codex manifest event is in Codex's closed set: $event" ;;
  esac
done
for event in $(jq -r '.hooks | keys_unsorted[]' "$CLAUDE_HOOKS"); do
  case " $(echo $CODEX_EVENTS) $(echo $CLAUDE_ONLY_EVENTS) " in
    *" $event "*) ok  "claude manifest event is known to some host: $event" ;;
    *)            bad "claude manifest event is known to some host: $event" ;;
  esac
done

claude_only_json="$(printf '%s\n' $CLAUDE_ONLY_EVENTS | jq -Rsc 'split("\n") | map(select(length > 0))')"
leaked="$(jq -r --argjson claude_only "$claude_only_json" \
  '[.hooks | keys_unsorted[] | select(. as $k | $claude_only | index($k))] | join(",")' "$CODEX_HOOKS")"
if [ -z "$leaked" ]; then
  ok "no claude-only event reaches the Codex twin"
else
  bad "no claude-only event reaches the Codex twin (found: $leaked)"
fi

# Twin comparison, with the Claude-only events removed first: everything Codex CAN run
# must still be byte-identical after async normalization.
claude_normalized="$(jq -Sc --argjson claude_only "$claude_only_json" '
  .hooks |= with_entries(select(.key as $k | $claude_only | index($k) | not))
  | .hooks.SubagentStart[].hooks[] |=
    (if has("asyncRewake") then .async = .asyncRewake | del(.asyncRewake) else . end)
' "$CLAUDE_HOOKS")"
codex_normalized="$(jq -Sc . "$CODEX_HOOKS")"
[ "$claude_normalized" = "$codex_normalized" ] \
  && ok "hook manifests normalize to the same behavior" \
  || bad "hook manifests normalize to the same behavior"
# The Stop hook now owns the synchronous audit. Its host timeout must outlive the
# runner's entire lease ceiling, not merely its default model timeout.
# shellcheck source=.agents/lib/verdict-audit-state.sh
source "$PLUGIN/.agents/lib/verdict-audit-state.sh"
verdict_audit_lock_max_seconds="${verdict_audit_lock_max_seconds:?audit lease missing}"
claude_stop_timeout="$(jq -r '.hooks.Stop[].hooks[].timeout' "$CLAUDE_HOOKS")"
codex_stop_timeout="$(jq -r '.hooks.Stop[].hooks[].timeout' "$CODEX_HOOKS")"
if [[ "$claude_stop_timeout" =~ ^[0-9]+$ \
   && "$codex_stop_timeout" == "$claude_stop_timeout" \
   && "$claude_stop_timeout" -gt "$verdict_audit_lock_max_seconds" ]]; then
  ok "Stop timeout outlives the synchronous auditor lease"
else
  bad "Stop timeout outlives the synchronous auditor lease (claude=$claude_stop_timeout codex=$codex_stop_timeout lease=$verdict_audit_lock_max_seconds)"
fi
jq -e '.hooks.SubagentStart[].hooks[] | .asyncRewake == true and has("async") == false' \
  "$CLAUDE_HOOKS" >/dev/null 2>&1 \
  && ok "claude SubagentStart uses asyncRewake" \
  || bad "claude SubagentStart uses asyncRewake"
jq -e '.hooks.SubagentStart[].hooks[] | .async == true and has("asyncRewake") == false' \
  "$CODEX_HOOKS" >/dev/null 2>&1 \
  && ok "codex SubagentStart stays inside its async schema" \
  || bad "codex SubagentStart stays inside its async schema"

# Full plugin prompts stay silent: cancellation is required, while prose recency is
# available only through the explicit standalone template.
user_prompt_commands="$(jq -r '.hooks.UserPromptSubmit[].hooks[].command' "$CODEX_HOOKS")"
user_prompt_count="$(printf '%s\n' "$user_prompt_commands" | grep -c . || true)"
[ "$user_prompt_count" = "1" ] && ok "UserPromptSubmit wires only cancellation" \
                                  || bad "UserPromptSubmit wires only cancellation (got $user_prompt_count commands)"
case "$user_prompt_commands" in
  *cancel-verdict-audit.sh*) ok "verdict cancellation remains wired" ;;
  *) bad "verdict cancellation remains wired" ;;
esac
case "$user_prompt_commands" in
  *rule-recency.sh*) bad "full plugin does not inject recurring prose" ;;
  *) ok "full plugin does not inject recurring prose" ;;
esac

echo
echo "## Every wired command runs on either host"
ROOT_EXPR='${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT}}'
while IFS= read -r cmd; do
  short="$(printf '%s' "$cmd" | sed -n 's/.*\/\.agents\/hooks\///p' | tr -d '"')"
  case "$cmd" in
    *"$ROOT_EXPR"*) ok "resolves the root for both hosts: ${short:-$cmd}" ;;
    *)              bad "resolves the root for both hosts (got: $cmd)"; continue ;;
  esac
  resolved="${cmd/"$ROOT_EXPR"/$PLUGIN}"
  if [[ "$resolved" =~ \"([^\"]+)\" ]]; then
    script="${BASH_REMATCH[1]}"
    [ -r "$script" ] && ok "wired script exists: ${script#"$PLUGIN"/}" \
                     || bad "wired script exists: ${script#"$PLUGIN"/}"
  else
    bad "command quotes its script path (got: $cmd)"
  fi
done < <(jq -r '.hooks[][].hooks[].command' "$CLAUDE_HOOKS" "$CODEX_HOOKS" | sort -u)

echo
echo "RESULT: $pass passed, $fail failed"
exit $(( fail > 0 ? 1 : 0 ))
