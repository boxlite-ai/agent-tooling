#!/usr/bin/env bash
# Exercise launcher argv/environment and the resulting prompt route without a host UI.
# shellcheck disable=SC2016 # The child shell expands these fixture arguments.
set -euo pipefail
plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir "$scratch/bin"
cat > "$scratch/bin/claude" <<'CLAUDE'
#!/usr/bin/env bash
if [[ "${1:-}" == --version ]]; then printf '2.1.278 (Claude Code)\n'; exit 0; fi
if [[ "${CLAUDE_TEST_IO:-}" == 1 ]]; then cat; printf 'child stderr\n' >&2; exit 17; fi
jq -nc --arg marker "${BOXLITE_CLAUDE_LOCAL_TIMED_PROMPTS:-}" --arg timeout "${CLAUDE_AFK_TIMEOUT_MS:-}" \
  --args '{marker:$marker,timeout:$timeout,argv:$ARGS.positional}' -- "$@"
CLAUDE
chmod +x "$scratch/bin/claude"
export PATH="$scratch/bin:$PATH" CLAUDE_PLUGIN_ROOT="$plugin" CLAUDE_AFK_TIMEOUT_MS=180000
unset PLUGIN_ROOT BOXLITE_CLAUDE_LOCAL_TIMED_PROMPTS
launcher="$plugin/scripts/claude-with-timed-prompts.sh"
failures=0
check() {
  if "$@" >/dev/null; then return; fi
  printf 'FAIL: %s\n' "$*" >&2
  failures=$((failures + 1))
}
route() {
  bash -c 'source "$1/.agents/lib/subagent.sh"; source "$1/.agents/lib/timed-user-prompt.sh";
    timed_user_prompt_instruction "$1" '\''{"id":"fixture","deadline":123,"spec":{"fallback":"split","prefix":"pr-size-exception:"}}'\''' _ "$plugin"
}

# A timeout variable alone says nothing about Remote Control being connected.
out="$(route)"
check test "${out#*plain text}" != "$out"
check test "${out#*Call AskUserQuestion}" = "$out"

out="$(bash "$launcher" --resume 'session with spaces')"
check jq -e --arg plugin "$plugin" '.marker=="1" and .timeout=="180000" and
  .argv==["--settings","{\"remoteControlAtStartup\":false,\"disableRemoteControl\":true}",
    "--resume","session with spaces","--plugin-dir",$plugin]' <<<"$out"
native_route="$(BOXLITE_CLAUDE_LOCAL_TIMED_PROMPTS="$(jq -r .marker <<<"$out")" route)"
check test "${native_route#*Call AskUserQuestion}" != "$native_route"

# Each unsupported invocation must clear an inherited capability and preserve argv.
fallback() {
  local out expected prompt
  out="$(BOXLITE_CLAUDE_LOCAL_TIMED_PROMPTS=1 bash "$launcher" "$@" 2>"$scratch/stderr")"
  expected="$(jq -nc --args '$ARGS.positional' -- "$@" --plugin-dir "$plugin")"
  check jq -e --argjson expected "$expected" '.marker=="" and .argv==$expected' <<<"$out"
  check grep -q 'non-blocking' "$scratch/stderr"
  prompt="$(BOXLITE_CLAUDE_LOCAL_TIMED_PROMPTS="$(jq -r .marker <<<"$out")" route)"
  check test "${prompt#*plain text}" != "$prompt"
}
for flag in --remote-control --remote-control=name --rc --rc=name remote-control rc \
  --settings=custom.json -p --print --print=json --background --bg --cloud --cloud=session; do
  fallback "$flag" 'value with spaces'
done
fallback --settings '{"remoteControlAtStartup":true,"model":"keep-me"}'
printf '{"model":"keep-file"}\n' > "$scratch/custom settings.json"
fallback --settings "$scratch/custom settings.json"
check test "$(cat "$scratch/custom settings.json")" = '{"model":"keep-file"}'

for timeout in '' 0 180001 invalid; do
  out="$(CLAUDE_AFK_TIMEOUT_MS="$timeout" BOXLITE_CLAUDE_LOCAL_TIMED_PROMPTS=1 route)"
  check test "${out#*plain text}" != "$out"
done

status=0
printf 'child stdin\n' | CLAUDE_TEST_IO=1 bash "$launcher" >"$scratch/stdout" 2>"$scratch/stderr" || status=$?
check test "$status" = 17
check test "$(cat "$scratch/stdout")" = 'child stdin'
check test "$(cat "$scratch/stderr")" = 'child stderr'
printf 'Claude timed launcher: %s failures\n' "$failures"
[[ "$failures" == 0 ]]
