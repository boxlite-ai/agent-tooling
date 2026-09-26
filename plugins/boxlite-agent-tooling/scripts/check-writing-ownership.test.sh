#!/usr/bin/env bash
# Exercise the repository gate with edits in an isolated checkout.
set -euo pipefail
plugin_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
gate="$plugin_root/scripts/check-writing-ownership.sh"
scratch="$(mktemp -d)"
trap 'rm -rf -- "$scratch"' EXIT
repo="$scratch/repo with spaces"
mkdir -p "$repo/plugins"
cp -R "$plugin_root" "$repo/plugins/boxlite-agent-tooling"
git init -q "$repo"
fixture_plugin="$repo/plugins/boxlite-agent-tooling"
policy="$fixture_plugin/.agents/skills/boxlite-writing/SKILL.md"
printf '%s\n' 'Report measured harbor outcomes before proposing another cargo routing change.' > "$policy"
refresh_guidance() { bash "$fixture_plugin/scripts/sync-guidance.sh" --force "$repo" >/dev/null 2>&1; }
refresh_guidance
pass=0
expect() { # description, exit status, diagnostic fragment
  local status=0
  bash "$gate" "$repo" > "$scratch/out" 2> "$scratch/err" || status=$?
  if [[ "$status" != "$2" ]] || { [[ -n "$3" ]] && ! grep -qF "$3" "$scratch/err"; }; then
    printf 'FAIL %s (exit=%s)\n' "$1" "$status" >&2
    cat "$scratch/err" >&2
    exit 1
  fi
  pass=$((pass + 1))
}
expect 'canonical source and generated block pass' 0 ''
mkdir -p "$repo/.claude/agents"
copy="$repo/.claude/agents/duplicate.md"
printf '%s\n' 'REPORT **MEASURED** harbor outcomes' 'before proposing another cargo routing change.' > "$copy"
expect 'untracked agent copy ignores case, markup and wrapping' 1 '.claude/agents/duplicate.md:1'
git -C "$repo" add .claude/agents/duplicate.md
expect 'tracked copy diagnostic references the skill by name' 1 'reference the boxlite-writing skill'
printf '%s\n' '<!-- agent-tooling:guidance:begin rev=fake sha256=000000000000 -->' \
  'Report measured harbor outcomes before proposing another cargo routing change.' \
  '<!-- agent-tooling:guidance:end -->' > "$copy"
expect 'generated markers in another file cannot exempt copies' 1 '.claude/agents/duplicate.md:2'
printf '%s\n' '```markdown' 'Report measured harbor outcomes before proposing another cargo routing change.' '```' > "$copy"
expect 'fenced example passes' 0 ''
printf '%s\n' 'Harbor retries use three attempts.' > "$copy"
expect 'task-specific instructions pass' 0 ''
cp "$repo/CLAUDE.md" "$scratch/claude"
printf '%s\n' '<!-- agent-tooling:guidance:begin rev=fake sha256=000000000000 -->' \
  'Report measured harbor outcomes before proposing another cargo routing change.' \
  '<!-- agent-tooling:guidance:end -->' >> "$repo/CLAUDE.md"
expect 'an unchecked bridge block cannot exempt copies' 1 'CLAUDE.md:'
cp "$scratch/claude" "$repo/CLAUDE.md"
printf '%s\n' 'Brief harbor reports prevent confusion.' >> "$policy"
expect 'skill edits do not require workflow regeneration' 0 ''
printf '%s\n' 'Brief harbor reports prevent confusion.' > "$copy"
expect 'new short rule is loaded on the next invocation' 1 '.claude/agents/duplicate.md:1'
rm "$copy"
expect 'deleted Markdown is not a duplicate' 0 ''
printf '\nReport measured harbor outcomes before proposing another cargo routing change.\n' >> "$repo/AGENTS.md"
expect 'copy outside the generated block fails' 1 'AGENTS.md:'
refresh_guidance
cp "$repo/AGENTS.md" "$scratch/agents"
sed 's/Apply the/Ignore the/' "$scratch/agents" > "$repo/AGENTS.md"
expect 'edited generated block fails integrity' 1 'edited by hand'
cp "$scratch/agents" "$repo/AGENTS.md"
printf ' \n' > "$policy"
expect 'empty canonical source fails closed' 1 'canonical source contains no checkable passages'
printf 'RESULT: %s passed, 0 failed\n' "$pass"
