#!/usr/bin/env bash
# Tests for scripts/sync-guidance.sh and the canonical guidance document itself.
#
# The document lint runs here (not in host-parity) because it is host-agnostic:
# the canonical text must stay DOMAIN-NEUTRAL — a consumer-repo detail that leaks
# in gets distributed to every consumer — and must stay small enough that the
# always-loaded block cannot degrade instruction adherence.
#
# The script tests are hermetic: consumers are throwaway Git repositories under
# mktemp, and "the canonical text changed upstream" is simulated with a scratch
# copy of the whole plugin whose guidance file is edited — the copy's own
# sync-guidance.sh then behaves as a newer tooling revision would.
#
# Run with:  bash plugins/boxlite-agent-tooling/scripts/sync-guidance.test.sh
set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SYNC="$PLUGIN_ROOT/scripts/sync-guidance.sh"
CANON="$PLUGIN_ROOT/guidance/workflow.md"
TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf -- "$TMP"' EXIT

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf '  PASS  %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }
check_eq() {
  local desc="$1" got="$2" want="$3"
  if [[ "$got" == "$want" ]]; then ok "$desc"; else bad "$desc (got=$got want=$want)"; fi
}

# Every invocation scrubs the two behavior-changing env vars so a caller's shell
# cannot skew a test.
run_sync() {  # $1 = sync-guidance.sh path, rest = args
  local script="$1"; shift
  env -u AGENT_TOOLING_SYNC_ACTIVE -u AGENT_TOOLING_GUIDANCE_FORCE bash "$script" "$@"
}

mkrepo() {  # $1 = directory
  git init -q "$1"
  git -C "$1" config user.email t@t.test
  git -C "$1" config user.name tester
}

marker_sha() { head -n1 "$1" | sed -E 's/.* sha256=([0-9a-f]{12}) -->$/\1/'; }
canon_sha12() { shasum -a 256 "$1" | awk '{print substr($1, 1, 12)}'; }

echo "## The canonical document is small and domain-neutral"
lines="$(wc -l < "$CANON" | tr -d ' ')"
[[ "$lines" -le 150 ]] && ok "canonical stays within the 150-line budget ($lines)" \
                       || bad "canonical exceeds the 150-line budget ($lines)"
# The repository-specific preface is eager context too, but deliberately lives
# outside the frozen canonical block. Keep its separate budget here so adding a local
# release rule cannot quietly undo the context reduction guarded below.
REPO_INSTRUCTIONS="$PLUGIN_ROOT/../../AGENTS.md"
preface="$(awk '/^<!-- agent-tooling:guidance:begin / { exit } { print }' \
  "$REPO_INSTRUCTIONS")"
preface_bytes="$(LC_ALL=C printf '%s' "$preface" | wc -c | tr -d ' ')"
preface_words="$(printf '%s' "$preface" | wc -w | tr -d ' ')"
if (( preface_bytes <= 2048 && preface_words <= 250 )); then
  ok "repository preface stays within its eager-context budget (${preface_words}w/${preface_bytes}b)"
else
  bad "repository preface exceeds 250 words or 2048 bytes (${preface_words}w/${preface_bytes}b)"
fi
# Line 1 is the managed-by notice and legitimately names the tooling repo; every
# other line must be free of repo-, path-, and toolchain-specific residue.
leaks="$(tail -n +2 "$CANON" | grep -inE 'boxlite|imagemanager|jailer' || true)"
[[ -z "$leaks" ]] && ok "no domain names leak past the notice line" \
                  || bad "domain names leak past the notice line: $leaks"
leaks="$(tail -n +2 "$CANON" | grep -nE '\]\(\./|/codex:|src/|`make [a-z]' || true)"
[[ -z "$leaks" ]] && ok "no repo-relative links or repo commands leak" \
                  || bad "repo-relative links or repo commands leak: $leaks"
grep -q 'agent-tooling:guidance:' "$CANON" \
  && bad "canonical must not contain its own marker string" \
  || ok "canonical does not contain its own marker string"

# Size alone is not a safety contract. Pin the eager kernel's non-negotiable
# semantics on single rules so prose reduction cannot delete one unnoticed.
require_semantic_rule() { # description, same-line ERE
  local description="$1" pattern="$2"
  if grep -Ei "$pattern" "$CANON" >/dev/null 2>&1; then
    ok "$description"
  else
    bad "$description"
  fi
}
require_semantic_rule "guidance pins source-first understanding" \
  'README/CONTRIBUTING.*actual source before editing'
require_semantic_rule "guidance pins focused scope" \
  'small, deliberate changes.*don.t rewrite or reformat unrelated code'
require_semantic_rule "guidance pins explicit errors and secret masking" \
  'Explicit errors.*fail fast.*Never swallow silently.*Mask secrets'
require_semantic_rule "guidance pins bounded concurrent work and cleanup" \
  'Concurrency:.*No unbounded.*Close/release'
require_semantic_rule "guidance pins input validation and shell safety" \
  'Security: no secrets.*Validate before.*Avoid shell execution with untrusted input'
require_semantic_rule "guidance pins full-revert red proof" \
  'revert .*every.* production change.*only the test remains'
require_semantic_rule "guidance constrains test-only compatibility adapters" \
  'test-only compatibility adapter.*must not implement the fix.*alter the defect check.*become the failure signal'
require_semantic_rule "guidance pins production-boundary tests" \
  'data must come from production code under test'
require_semantic_rule "guidance pins evidence-qualified reporting" \
  'Don.t claim tests passed unless they actually ran.*residual risk'
require_semantic_rule "guidance pins auditor ownership of proof" \
  'auditor .*never you.* writes the dossier'

echo
echo "## A repository with no instructions files gets the canonical layout"
R="$TMP/fresh"; mkrepo "$R"
run_sync "$SYNC" "$R" > "$TMP/out" 2> "$TMP/err"
check_eq "sync succeeds" "$?" 0
[[ -f "$R/AGENTS.md" ]] && ok "creates AGENTS.md" || bad "creates AGENTS.md"
head -n1 "$R/AGENTS.md" | grep -qE '^<!-- agent-tooling:guidance:begin rev=[^ ]+ sha256=[0-9a-f]{12} -->$' \
  && ok "begin marker is well-formed" || bad "begin marker is well-formed"
check_eq "marker records the canonical content hash" "$(marker_sha "$R/AGENTS.md")" "$(canon_sha12 "$CANON")"
tail -n1 "$R/AGENTS.md" | grep -qxF '<!-- agent-tooling:guidance:end -->' \
  && ok "end marker closes the file" || bad "end marker closes the file"
check_eq "creates the CLAUDE.md bridge" "$(head -n1 "$R/CLAUDE.md" 2>/dev/null)" "@AGENTS.md"
run_sync "$SYNC" --check "$R" > "$TMP/out" 2> "$TMP/err"
check_eq "check passes on the fresh layout" "$?" 0
[[ ! -s "$TMP/err" ]] && ok "check is silent when healthy" || bad "check is silent when healthy"
printf '\nUse plan mode for risky changes.\n' >> "$R/CLAUDE.md"
run_sync "$SYNC" --check "$R" >/dev/null 2>&1
check_eq "an annotated bridge stays exempt" "$?" 0
run_sync "$SYNC" "$R" >/dev/null 2>&1
check_eq "one block despite the bridge annotation" "$(grep -c '^<!-- agent-tooling:guidance:begin ' "$R/CLAUDE.md" || true)" 0

echo
echo "## The rendered block composes with Markdown formatters"
# The canonical being formatter-clean is not enough: a formatter judges the
# COMPOSITION, and an HTML comment butted against the following block is a
# formatting error. Consumers whose formatter covers root markdown fail CI on it.
check_eq "a blank line follows the begin marker" \
  "$(awk '/^<!-- agent-tooling:guidance:begin /{getline; print ($0 == "" ? "yes" : "no"); exit}' "$R/AGENTS.md")" "yes"
check_eq "the end marker follows content directly" \
  "$(awk '/^<!-- agent-tooling:guidance:end -->$/{print (prev == "" ? "blank" : "text"); exit} {prev = $0}' "$R/AGENTS.md")" "text"
# Layout drift must be repairable even though the content already matches —
# otherwise byte-stability would freeze every block ever written in the old shape.
OLD="$TMP/old-layout"; mkrepo "$OLD"
run_sync "$SYNC" "$OLD" >/dev/null 2>&1
awk '/^<!-- agent-tooling:guidance:begin /{print; getline; next} {print}' "$OLD/AGENTS.md" > "$OLD/tmp" && mv "$OLD/tmp" "$OLD/AGENTS.md"
check_eq "the old layout is detectably different" \
  "$(awk '/^<!-- agent-tooling:guidance:begin /{getline; print ($0 == "" ? "yes" : "no"); exit}' "$OLD/AGENTS.md")" "no"
run_sync "$SYNC" --check "$OLD" >/dev/null 2>&1
check_eq "check does not call an old layout hand-edited" "$?" 0
run_sync "$SYNC" "$OLD" > "$TMP/out" 2>&1
check_eq "sync repairs the layout" \
  "$(awk '/^<!-- agent-tooling:guidance:begin /{getline; print ($0 == "" ? "yes" : "no"); exit}' "$OLD/AGENTS.md")" "yes"
run_sync "$SYNC" --check "$OLD" >/dev/null 2> "$TMP/err"
check_eq "the repaired block checks clean" "$?" 0
[[ ! -s "$TMP/err" ]] && ok "and silently" || bad "and silently"

echo
echo "## Re-running is a byte-stable no-op"
cp "$R/AGENTS.md" "$TMP/snap"
run_sync "$SYNC" "$R" > "$TMP/out" 2>/dev/null
check_eq "second sync succeeds" "$?" 0
cmp -s "$R/AGENTS.md" "$TMP/snap" && ok "file bytes are unchanged" || bad "file bytes are unchanged"
grep -q 'up to date' "$TMP/out" && ok "reports up to date" || bad "reports up to date"

echo
echo "## Appending preserves the consumer's own content"
R="$TMP/append"; mkrepo "$R"
printf '# My Project\n\ndomain knowledge\nno trailing newline' > "$R/AGENTS.md"
run_sync "$SYNC" "$R" >/dev/null 2>&1
check_eq "sync succeeds" "$?" 0
head -n1 "$R/AGENTS.md" | grep -qx '# My Project' && ok "consumer content stays first" \
                                                  || bad "consumer content stays first"
grep -q 'no trailing newline' "$R/AGENTS.md" && ok "unterminated last line survives" \
                                             || bad "unterminated last line survives"
check_eq "exactly one block" "$(grep -c '^<!-- agent-tooling:guidance:begin ' "$R/AGENTS.md")" 1
run_sync "$SYNC" --check "$R" >/dev/null 2>&1
check_eq "check passes after append" "$?" 0
# Exactly one blank line before the marker, however many the file ended with: a
# strip-and-resplice cycle otherwise stacks one more each time, and the block is
# never rewritten once current, so the padding would ship to consumers.
check_eq "one blank line separates content from the block" \
  "$(awk '/^<!-- agent-tooling:guidance:begin /{print blank; exit} /^[[:space:]]*$/{blank++; next} {blank=0}' "$R/AGENTS.md")" 1
R="$TMP/padded"; mkrepo "$R"
printf '# Padded\n\ncontent\n\n\n\n' > "$R/AGENTS.md"
run_sync "$SYNC" "$R" >/dev/null 2>&1
check_eq "trailing blank lines collapse to one" \
  "$(awk '/^<!-- agent-tooling:guidance:begin /{print blank; exit} /^[[:space:]]*$/{blank++; next} {blank=0}' "$R/AGENTS.md")" 1
check_eq "padded file keeps its content" "$(grep -c '^content$' "$R/AGENTS.md")" 1

echo
echo "## Symlinked names collapse to one physical splice"
R="$TMP/symlink"; mkrepo "$R"
printf '# Real file\n' > "$R/CLAUDE.md"
ln -s CLAUDE.md "$R/AGENTS.md"
run_sync "$SYNC" "$R" >/dev/null 2>&1
check_eq "sync succeeds" "$?" 0
check_eq "one block despite two names" "$(grep -c '^<!-- agent-tooling:guidance:begin ' "$R/CLAUDE.md")" 1
[[ -L "$R/AGENTS.md" ]] && ok "the symlink survives the splice" || bad "the symlink survives the splice"

echo
echo "## Two independent regular files are both managed"
R="$TMP/both"; mkrepo "$R"
printf '# A\n' > "$R/AGENTS.md"
printf '# C\n' > "$R/CLAUDE.md"
run_sync "$SYNC" "$R" >/dev/null 2>&1
check_eq "sync succeeds" "$?" 0
check_eq "AGENTS.md gets the block" "$(grep -c '^<!-- agent-tooling:guidance:begin ' "$R/AGENTS.md")" 1
check_eq "CLAUDE.md gets the block" "$(grep -c '^<!-- agent-tooling:guidance:begin ' "$R/CLAUDE.md")" 1

echo
echo "## A newer canonical text replaces the block and flags staleness"
# The scratch plugin copy stands in for a newer adopted tooling revision.
PLUGIN2="$TMP/plugin2"
cp -R "$PLUGIN_ROOT" "$PLUGIN2"
printf -- '- Extra shared rule for this test.\n' >> "$PLUGIN2/guidance/workflow.md"
R="$TMP/stale"; mkrepo "$R"
run_sync "$SYNC" "$R" >/dev/null 2>&1
git -C "$R" add -A && git -C "$R" commit -qm base
run_sync "$SYNC" --check "$R" >/dev/null 2>&1
check_eq "current revision checks clean" "$?" 0
run_sync "$PLUGIN2/scripts/sync-guidance.sh" --check "$R" >/dev/null 2> "$TMP/err"
check_eq "newer revision's check still exits 0" "$?" 0
grep -q 'behind the adopted tooling revision' "$TMP/err" && ok "newer revision warns stale" \
                                                        || bad "newer revision warns stale"
run_sync "$PLUGIN2/scripts/sync-guidance.sh" "$R" > "$TMP/out" 2>/dev/null
check_eq "newer revision splices" "$?" 0
grep -q 'Extra shared rule for this test' "$R/AGENTS.md" && ok "block carries the new text" \
                                                         || bad "block carries the new text"
check_eq "marker hash follows the new content" "$(marker_sha "$R/AGENTS.md")" "$(canon_sha12 "$PLUGIN2/guidance/workflow.md")"
run_sync "$SYNC" --check "$R" >/dev/null 2> "$TMP/err"
check_eq "old revision now sees it as stale, not broken" "$?" 0
grep -q 'behind the adopted tooling revision' "$TMP/err" && ok "staleness is symmetric" \
                                                         || bad "staleness is symmetric"

echo
echo "## Uncommitted consumer edits are never entangled with a splice"
git -C "$R" add -A && git -C "$R" commit -qm adopt-plugin2
printf 'domain note\n' >> "$R/AGENTS.md"   # tracked file, now dirty, outside the block
printf -- '- Second extra rule.\n' >> "$PLUGIN2/guidance/workflow.md"
cp "$R/AGENTS.md" "$TMP/snap"
run_sync "$PLUGIN2/scripts/sync-guidance.sh" "$R" >/dev/null 2> "$TMP/err"
check_eq "sync with a dirty target still exits 0" "$?" 0
grep -q 'uncommitted changes' "$TMP/err" && ok "explains the skip" || bad "explains the skip"
cmp -s "$R/AGENTS.md" "$TMP/snap" && ok "dirty file is untouched" || bad "dirty file is untouched"
git -C "$R" add -A && git -C "$R" commit -qm note
run_sync "$PLUGIN2/scripts/sync-guidance.sh" "$R" >/dev/null 2>&1
check_eq "sync proceeds once committed" "$?" 0
grep -q 'domain note' "$R/AGENTS.md" && ok "consumer edit survives the splice" \
                                     || bad "consumer edit survives the splice"
grep -q 'Second extra rule' "$R/AGENTS.md" && ok "block advanced under the edit" \
                                           || bad "block advanced under the edit"

echo
echo "## Splicing never tightens a file's permissions"
# mktemp is 0600 and mv carries that mode onto the destination, so an unguarded
# splice turns a committed, readable instructions file owner-only — invisible to
# git, which records only the exec bit, but not to other uids on a CI runner or in
# a container. Every write path is covered: replace, append, and both creations.
mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }
default_mode="$(printf '%o' "$(( 0666 & ~0$(umask) ))")"
R="$TMP/modes"; mkrepo "$R"
printf '# Perms\n' > "$R/AGENTS.md"
chmod 644 "$R/AGENTS.md"
run_sync "$SYNC" "$R" >/dev/null 2>&1
check_eq "append preserves the existing mode" "$(mode_of "$R/AGENTS.md")" "644"
check_eq "a created bridge uses the umask default" "$(mode_of "$R/CLAUDE.md")" "$default_mode"
chmod 640 "$R/AGENTS.md"
run_sync "$PLUGIN2/scripts/sync-guidance.sh" "$R" >/dev/null 2>&1
check_eq "replace preserves a non-default mode" "$(mode_of "$R/AGENTS.md")" "640"
R="$TMP/modes-fresh"; mkrepo "$R"
run_sync "$SYNC" "$R" >/dev/null 2>&1
check_eq "a created AGENTS.md uses the umask default" "$(mode_of "$R/AGENTS.md")" "$default_mode"

# Both mode operations must fail the splice rather than fall through to mv,
# which would hand the destination mktemp's 0600 — the defect being fixed. The
# stubs shadow one command each on PATH; everything else still resolves.
stub_dir() {  # $1 = command to break, prints a PATH prefix directory
  local d="$TMP/stub-$1"
  mkdir -p "$d"
  printf '#!/bin/sh\nexit 1\n' > "$d/$1"
  chmod +x "$d/$1"
  printf '%s' "$d"
}
R="$TMP/modes-fail"; mkrepo "$R"
printf '# Fail\n' > "$R/AGENTS.md"
chmod 644 "$R/AGENTS.md"
PATH="$(stub_dir stat):$PATH" run_sync "$SYNC" "$R" >/dev/null 2> "$TMP/err"
check_eq "unreadable mode aborts the splice" "$?" 1
grep -q 'cannot read the mode' "$TMP/err" && ok "names the unreadable mode" || bad "names the unreadable mode"
check_eq "the destination is left untouched" "$(mode_of "$R/AGENTS.md")" "644"
check_eq "no block was written" "$(grep -c '^<!-- agent-tooling:guidance:begin ' "$R/AGENTS.md")" 0
PATH="$(stub_dir chmod):$PATH" run_sync "$SYNC" "$R" >/dev/null 2> "$TMP/err"
check_eq "a failed chmod aborts the splice" "$?" 1
grep -q 'cannot set mode' "$TMP/err" && ok "names the failed chmod" || bad "names the failed chmod"
check_eq "still no block written" "$(grep -c '^<!-- agent-tooling:guidance:begin ' "$R/AGENTS.md")" 0

echo
echo "## A splice from a modified canonical says so in the stamp"
# The stamp is only useful if `git show <rev>:guidance/workflow.md` reproduces the
# block. Splicing from a working tree whose canonical is modified would name a
# revision that never held the text — the exact way a misleading stamp reached a
# consumer during the first rollout.
PLUGIN3="$TMP/plugin3"
cp -R "$PLUGIN_ROOT" "$PLUGIN3"
git init -q "$PLUGIN3"
git -C "$PLUGIN3" config user.email t@t.test
git -C "$PLUGIN3" config user.name tester
git -C "$PLUGIN3" add -A
git -C "$PLUGIN3" commit -qm plugin
R="$TMP/dirty-canon"; mkrepo "$R"
printf -- '- Uncommitted rule.\n' >> "$PLUGIN3/guidance/workflow.md"
run_sync "$PLUGIN3/scripts/sync-guidance.sh" "$R" >/dev/null 2> "$TMP/err"
check_eq "sync from a modified canonical succeeds" "$?" 0
grep -q 'canonical guidance is modified' "$TMP/err" && ok "warns about the modified canonical" \
                                                    || bad "warns about the modified canonical"
head -1 "$R/AGENTS.md" | grep -q -- '-dirty sha256=' && ok "stamp is marked -dirty" \
                                                     || bad "stamp is marked -dirty"
run_sync "$PLUGIN3/scripts/sync-guidance.sh" --check "$R" >/dev/null 2>&1
check_eq "a -dirty stamp still parses as a valid block" "$?" 0
git -C "$PLUGIN3" add -A && git -C "$PLUGIN3" commit -qm canon
run_sync "$PLUGIN3/scripts/sync-guidance.sh" "$R" >/dev/null 2> "$TMP/err"
head -1 "$R/AGENTS.md" | grep -q -- '-dirty' && bad "a clean re-splice drops the suffix" \
                                             || ok "a clean re-splice drops the suffix"

echo
echo "## A hand-edited block fails closed until forced"
R="$TMP/tamper"; mkrepo "$R"
run_sync "$SYNC" "$R" >/dev/null 2>&1
awk '{print} /^<!-- agent-tooling:guidance:begin /{print "TAMPERED"}' "$R/AGENTS.md" > "$R/AGENTS.md.new"
mv "$R/AGENTS.md.new" "$R/AGENTS.md"
run_sync "$SYNC" --check "$R" >/dev/null 2> "$TMP/err"
check_eq "check rejects the tamper" "$?" 1
grep -q 'edited by hand' "$TMP/err" && ok "check names the hand edit" || bad "check names the hand edit"
run_sync "$SYNC" "$R" >/dev/null 2> "$TMP/err"
check_eq "sync refuses to overwrite the tamper" "$?" 1
grep -q 'TAMPERED' "$R/AGENTS.md" && ok "tampered content is preserved for inspection" \
                                  || bad "tampered content is preserved for inspection"
run_sync "$SYNC" --force "$R" >/dev/null 2>&1
check_eq "--force restores the block" "$?" 0
run_sync "$SYNC" --check "$R" >/dev/null 2>&1
check_eq "check passes after the restore" "$?" 0
awk '{print} /^<!-- agent-tooling:guidance:begin /{print "TAMPERED"}' "$R/AGENTS.md" > "$R/AGENTS.md.new"
mv "$R/AGENTS.md.new" "$R/AGENTS.md"
env -u AGENT_TOOLING_SYNC_ACTIVE AGENT_TOOLING_GUIDANCE_FORCE=1 bash "$SYNC" "$R" >/dev/null 2>&1
check_eq "AGENT_TOOLING_GUIDANCE_FORCE=1 reaches force through install.sh" "$?" 0
run_sync "$SYNC" --check "$R" >/dev/null 2>&1
check_eq "env-forced restore checks clean" "$?" 0

echo
echo "## Malformed markers fail closed in both modes"
grep -vxF '<!-- agent-tooling:guidance:end -->' "$R/AGENTS.md" > "$R/AGENTS.md.new"
mv "$R/AGENTS.md.new" "$R/AGENTS.md"
run_sync "$SYNC" --check "$R" >/dev/null 2> "$TMP/err"
check_eq "check rejects a missing end marker" "$?" 1
grep -q 'malformed' "$TMP/err" && ok "check names the malformed markers" || bad "check names the malformed markers"
run_sync "$SYNC" "$R" >/dev/null 2>&1
check_eq "sync refuses a malformed block" "$?" 1

echo
echo "## Lifecycle installs defer; explicit checks still run"
R="$TMP/deferred"; mkrepo "$R"
AGENT_TOOLING_SYNC_ACTIVE=1 bash "$SYNC" "$R" >/dev/null 2> "$TMP/err"
check_eq "deferred sync exits 0" "$?" 0
grep -q 'deferred' "$TMP/err" && ok "says it deferred" || bad "says it deferred"
[[ ! -e "$R/AGENTS.md" && ! -e "$R/CLAUDE.md" ]] && ok "background path created nothing" \
                                                 || bad "background path created nothing"
R="$TMP/fresh"
AGENT_TOOLING_SYNC_ACTIVE=1 bash "$SYNC" --check "$R" >/dev/null 2>&1
check_eq "check ignores the lifecycle flag" "$?" 0

echo
echo "## Unmanageable layouts fail closed"
R="$TMP/outside"; mkrepo "$R"
printf 'external\n' > "$TMP/external.md"
ln -s "$TMP/external.md" "$R/CLAUDE.md"
run_sync "$SYNC" "$R" >/dev/null 2> "$TMP/err"
check_eq "sync refuses an outside-repo target" "$?" 1
grep -q 'no manageable instructions file' "$TMP/err" && ok "names the unmanageable layout" \
                                                    || bad "names the unmanageable layout"
check_eq "the outside file is untouched" "$(cat "$TMP/external.md")" "external"
R="$TMP/none"; mkrepo "$R"
run_sync "$SYNC" --check "$R" >/dev/null 2> "$TMP/err"
check_eq "check fails when no file carries the block" "$?" 1
grep -q 'install.sh' "$TMP/err" && ok "points at the installer" || bad "points at the installer"

echo
printf 'RESULT: %d passed, %d failed\n' "$pass" "$fail"
exit $(( fail > 0 ? 1 : 0 ))
