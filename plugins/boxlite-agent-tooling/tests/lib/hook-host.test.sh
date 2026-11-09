#!/usr/bin/env bash
# Tests for .agents/lib/hook-host.sh
#
# Exercise exported markers, shared payload parsing, and actual manifest commands.
# Aliases and nested installations must select both the intended host and its tree.
#
# Run with:  bash tests/lib/hook-host.test.sh
# Exits non-zero on any failure.
set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.agents/lib" && pwd)"
unset BOXLITE_HOOK_HOST

# Sourcing is itself under test: a library that writes to stdout or exits corrupts
# every hook that loads it, and hooks here speak JSON on stdout.
source_output="$(source "$LIB_DIR/hook-host.sh" 2>&1)"
source_status=$?

# shellcheck source=../../.agents/lib/hook-host.sh
source "$LIB_DIR/hook-host.sh"

# shellcheck source=assert.sh
source "$LIB_DIR/../../tests/lib/assert.sh"

echo "## Loading the library is inert"
check_eq "sourcing writes nothing to stdout or stderr" "$source_output" ""
check_eq "sourcing succeeds"                           "$source_status" "0"

marker_kind() {  # marker, exported|local
  (
    unset BOXLITE_HOOK_HOST
    export PLUGIN_ROOT=/codex/root CLAUDE_PLUGIN_ROOT=/claude/root
    BOXLITE_HOOK_HOST="$1"
    [[ "$2" != exported ]] || export BOXLITE_HOOK_HOST
    hook_host_kind
  )
}
roots_only_kind() {  # PLUGIN_ROOT CLAUDE_PLUGIN_ROOT; "-" means absent
  (
    unset BOXLITE_HOOK_HOST PLUGIN_ROOT CLAUDE_PLUGIN_ROOT
    [[ "$1" == - ]] || export PLUGIN_ROOT="$1"
    [[ "$2" == - ]] || export CLAUDE_PLUGIN_ROOT="$2"
    hook_host_kind
  )
}

echo
echo "## Only an exported marker names a host"
check_eq "an exported claude marker names Claude Code" "$(marker_kind claude exported)" claude
check_eq "an exported codex marker names Codex" "$(marker_kind codex exported)" codex
check_eq "an explicit generic marker names no host" "$(marker_kind unknown exported)" unknown
check_eq "an invalid marker cannot name a host" "$(marker_kind invalid exported)" unknown
check_eq "an empty marker names no host" "$(marker_kind '' exported)" unknown
check_eq "a local marker cannot name a host" "$(marker_kind claude local)" unknown
check_eq "PLUGIN_ROOT alone names no host" "$(roots_only_kind /codex/root -)" unknown
check_eq "CLAUDE_PLUGIN_ROOT alone names no host" "$(roots_only_kind - /claude/root)" unknown
check_eq "no marker and no roots names no host" "$(roots_only_kind - -)" unknown

echo
echo "## An exported value cannot forge the marker"
# A whole-table scan would read this value's second line as BOXLITE_HOOK_HOST's entry.
forged_marker_kind() {
  (
    unset BOXLITE_HOOK_HOST
    BOXLITE_HOOK_HOST=codex
    export DECOY=$'value\ndeclare -x BOXLITE_HOOK_HOST="codex"'
    hook_host_kind
  )
}
check_eq "a forged marker entry in another value is not a host" "$(forged_marker_kind)" unknown

echo
echo "## Command segments"
segment() { hook_command_segment_verb "$1" 'git[[:space:]]+(commit|push)' || printf none; }
check_eq "a leading verb matches" "$(segment 'git push origin main')" push
check_eq "a chained verb matches" "$(segment 'make test && git commit -m x')" commit
check_eq "a piped verb matches" "$(segment 'true | git push')" push
check_eq "a verb after assignments matches" "$(segment 'GIT_TRACE=1 git push')" push
check_eq "a verb on a later line matches" "$(segment $'cd repo\ngit push')" push
check_eq "a verb in a substitution matches" "$(segment 'x=$(git push origin)')" push
check_eq "a verb in backticks matches" "$(segment 'x=`git push origin`')" push
check_eq "a quoted mention does not match" "$(segment 'echo "git push"')" none
check_eq "a longer word does not match" "$(segment 'git pushy')" none
check_eq "another program does not match" "$(segment 'legit push')" none
check_eq "a gh pattern returns its verb" \
  "$(hook_command_segment_verb 'gh pr create --fill' 'gh[[:space:]]+pr[[:space:]]+(create|edit)')" create

echo
echo "## Payload working directory"
workdir() { hook_payload_workdir "$1" /fallback || printf '<fail>'; }
check_eq "workdir wins over cwd" "$(workdir '{"tool_input":{"workdir":"/w","cwd":"/c"},"cwd":"/top"}')" /w
check_eq "tool cwd wins over payload cwd" "$(workdir '{"tool_input":{"cwd":"/c"},"cwd":"/top"}')" /c
check_eq "payload cwd is used next" "$(workdir '{"cwd":"/top"}')" /top
check_eq "the fallback is used last" "$(workdir '{}')" /fallback
check_eq "an empty directory fails" "$(workdir '{"cwd":""}')" '<fail>'
check_eq "a non-string directory fails" "$(workdir '{"cwd":7}')" '<fail>'
check_eq "a NUL in the directory fails" "$(workdir '{"cwd":"/a\u0000b"}')" '<fail>'

echo
echo "## Manifest identity survives aliases and nesting"
plugin_root="$(cd "$LIB_DIR/../.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
# The manifest selects a fixture hook, which calls the real detector. A wrong
# plugin root reaches a different fixture tree and is visible in the result.
for tree in "inner ' plugin" outer; do
  fixture="$scratch/$tree"
  mkdir -p "$fixture/.agents/hooks" "$fixture/.agents/lib"
  cp "$LIB_DIR/hook-host.sh" "$fixture/.agents/lib/hook-host.sh"
  while IFS= read -r hook; do
    cat > "$fixture/.agents/hooks/$hook" <<'HOOK'
#!/usr/bin/env bash
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$root/.agents/lib/hook-host.sh"
printf '%s:%s' "$(hook_host_kind)" "$root"
HOOK
  done < <(jq -r '.hooks[][].hooks[].command' "$plugin_root/hooks/hooks.json" |
    sed -n 's,.*\.agents/hooks/\([^"/]*\)".*,\1,p' | sort -u)
done
for host in codex claude unknown; do
  case "$host" in
    codex) manifest="$plugin_root/hooks/codex-hooks.json" ;;
    claude) manifest="$plugin_root/hooks/hooks.json" ;;
    unknown) manifest="$plugin_root/$(jq -r .hooks "$plugin_root/plugin.json")" ;;
  esac
  for roots in aliases nested; do
    while IFS= read -r command; do
      result="$(
        export BOXLITE_HOOK_HOST=claude
        [[ "$host" != claude ]] || export BOXLITE_HOOK_HOST=codex
        export PLUGIN_ROOT="$scratch/inner ' plugin" CLAUDE_PLUGIN_ROOT="$scratch/inner ' plugin"
        if [[ "$roots" == nested ]]; then
          if [[ "$host" == claude ]]; then export PLUGIN_ROOT="$scratch/outer"
          else export CLAUDE_PLUGIN_ROOT="$scratch/outer"; fi
        fi
        bash -c "$command"
      )"
      check_eq "$host/$roots manifest selects host and tree" "$result" "$host:$scratch/inner ' plugin"
    done < <(jq -r '.hooks[][].hooks[].command' "$manifest" | sort -u)
  done
done

assert_result
