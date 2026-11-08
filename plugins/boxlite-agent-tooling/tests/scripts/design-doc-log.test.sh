#!/usr/bin/env bash
# The research log beside a design (design #388): stored per design ID in the clone's
# common directory, bound into the audit hash, shown after the design. Provider responses
# are fixtures; no live services.
set -uo pipefail
plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir "$scratch/bin" "$scratch/repo"
export DOC_FIXTURE="$scratch/response.json"
cat > "$scratch/bin/gh" <<'SH'
#!/usr/bin/env bash
cat "$DOC_FIXTURE"
SH
chmod +x "$scratch/bin/gh"
export PATH="$scratch/bin:$PATH"
unset GH_REPO GH_HOST GIT_DIR GIT_WORK_TREE NOTION_TOKEN LINEAR_API_KEY
git -C "$scratch/repo" init -q
git -C "$scratch/repo" -c core.hooksPath=/dev/null -c user.name=test \
  -c user.email=test@example.invalid commit -qm initial --allow-empty
git -C "$scratch/repo" branch -m feature
cd "$scratch/repo" || exit 1
cli="$plugin/scripts/design-doc.sh"
url=https://github.com/example/project/issues/1
other=https://github.com/example/project/issues/2
logs="$(git rev-parse --path-format=absolute --git-common-dir)/agent-tooling-design-log"
body=$'## TL;DR\n\nStore research logs beside designs.'
log_a=$'| Source | Queries |\n| --- | --- |\n| arXiv | 2 |\n'
pass=0 fail=0
report() { # description, 0 when the check held
  if [[ "$2" == 0 ]]; then printf 'PASS %s\n' "$1"; pass=$((pass+1))
  else printf 'FAIL %s\n' "$1"; fail=$((fail+1)); fi
}
outcome() { # description, wanted status, status
  if [[ "$3" == "$2" ]]; then report "$1" 0
  else report "$1 (exit $3, wanted $2)" 1; cat "$scratch/err"; fi
}
same() { [[ "$2" == "$3" ]]; report "$1" $?; }
differs() { [[ "$2" != "$3" ]]; report "$1" $?; }
contains() { [[ "$2" == *"$3"* ]]; report "$1" $?; }
lacks() { [[ "$2" != *"$3"* ]]; report "$1" $?; }
expect() { # description, exit status, arguments
  local description="$1" expected="$2" status=0
  shift 2
  bash "$cli" "$@" > "$scratch/out" 2> "$scratch/err" </dev/null || status=$?
  outcome "$description" "$expected" "$status"
}
store() { # description, exit status, log text
  local status=0
  printf '%s' "$3" | bash "$cli" log > "$scratch/out" 2> "$scratch/err" || status=$?
  outcome "$1" "$2" "$status"
}
github_doc() { # issue URL, body
  jq -nc --arg url "$1" --arg body "$2" '{html_url:$url,body:$body}' > "$DOC_FIXTURE"
}
sha() { perl -MDigest::SHA=sha256_hex -0777 -ne 'print sha256_hex($_)'; }
gate() { # operation [argument] -> design_doc_binding through the library, as the hook calls it
  bash -c 'for lib in verdict-audit-state reply-summary concise-writing design-doc; do
      source "$1/.agents/lib/$lib.sh" || exit 2; done
    design_doc_binding "$2" "$PWD" "${3:-}"' gate "$plugin" "$@"
}
live_hash() { # [repository root] -> the content hash the gate binds verdicts to
  bash -c 'for lib in verdict-audit-state reply-summary concise-writing design-doc; do
      source "$1/.agents/lib/$lib.sh" || exit 2; done
    _design_doc_digest "$3" "$2"' digest "$plugin" "$url" "${1:-$PWD}" 2>/dev/null
}
design_id() { # URL -> the design ID its log is keyed by
  bash -c 'source "$1/.agents/lib/design-doc.sh" || exit 2; _design_doc_id "$2"' id "$plugin" "$1"
}
pass_with_advice() { # SHA-256 -> records a PASS and empty advice for it
  jq -nc --arg sha "$1" '{content_sha256:$sha,verdict:"PASS",findings:[]}' \
    | bash "$cli" verdict >/dev/null 2>"$scratch/err" &&
  jq -nc --arg sha "$1" '{content_sha256:$sha,advice:[]}' \
    | bash "$cli" advice >/dev/null 2>>"$scratch/err"
}
edit_status() { local status=0; gate edit >/dev/null 2>"$scratch/err" || status=$?; printf '%s' "$status"; }

store 'a log needs a registered design' 1 "$log_a"
github_doc "$url" "$body"
expect 'register the design' 0 register "$url"
plain="$(printf '%s' "$body" | sha)"
same 'a design that never stored a log keeps the plain content hash' "$(live_hash)" "$plain"

store 'a log is stored for the bound design' 0 "$log_a"
same 'storing prints the bound URL' "$(cat "$scratch/out")" "$url"
same 'the hash matches the recorded labelled test vector' "$(live_hash)" \
  3cd6e7fa9fa45ed6635b37c10ab5852da4b4f8a56a39280e4a4e2c9cfca32597
expect 'show prints the design and then the log' 0 show
same 'show output carries the design, a log heading, the log hash, and the log' \
  "$(cat "$scratch/out")" \
  "$body"$'\n\n## Research log (local)\n\nsha256: '"$(printf '%s' "$log_a" | sha)"$'\n\n'"${log_a%$'\n'}"

with_log="$(live_hash)"
pass_with_advice "$with_log"
outcome 'a PASS for the design and its log allows edits' 0 "$(edit_status)"
store 'the log is edited' 0 $'| Source | Queries |\n| --- | --- |\n| arXiv | 3 |\n'
outcome 'editing the log requests a new audit' 3 "$(edit_status)"
store 'the log is deleted' 0 ''
outcome 'deleting the log requests a new audit' 3 "$(edit_status)"
differs 'a deleted log never returns to the no-log hash' "$(live_hash)" "$plain"
expect 'show marks the deleted log' 0 show
contains 'show names the tombstone' "$(cat "$scratch/out")" '(deleted)'

store 'the log is stored again' 0 "$log_a"
same 'restoring the audited log restores its hash' "$(live_hash)" "$with_log"
# The advisor reads the design and its log, so a quote from the log anchors advice.
jq -nc --arg sha "$with_log" \
  '{content_sha256:$sha,advice:["Research log: add a third index. Why: \"| arXiv | 2 |\". Try: log OpenAlex."]}' \
  | bash "$cli" advice >/dev/null 2>"$scratch/err"
same 'advice quoting the stored log is kept' \
  "$(jq -r '.advice | length' "${logs%/*}/agent-tooling-design-advice.json")" 1

github_doc "$other" $'## TL;DR\n\nA second design.'
expect 'register design B' 0 register "$other"
expect 'design B shows no log' 0 show
lacks "design B never sees design A's log" "$(cat "$scratch/out")" 'Research log'
store 'design B stores its own log' 0 $'B only\n'
github_doc "$url" "$body"
expect 'register design A again' 0 register "$url"
expect 'design A shows its log after switching back' 0 show
contains 'design A keeps its own log' "$(cat "$scratch/out")" '| arXiv | 2 |'
lacks 'design A never shows design B'"'"'s log' "$(cat "$scratch/out")" 'B only'
same 'each design has its own log file' "$(find "$logs" -type f | wc -l | tr -d ' ')" 2

# URL spellings of one design share its log; the key is the provider's design ID.
notion_id=0123456789abcdef0123456789abcdef
same 'Notion slug and dashed-ID URLs name one design' \
  "$(design_id "https://www.notion.so/team/Plan-$notion_id")" \
  "$(design_id "https://notion.so/01234567-89AB-CDEF-0123-456789ABCDEF")"
same 'GitHub owner and repository case name one design' \
  "$(design_id https://github.com/Example/Project/issues/1)" "$(design_id "$url")"

# One store for the clone: a subdirectory and a linked worktree reach the same log, and it
# outlives the worktree; a new log from either side sends the design back to audit.
mkdir -p "$scratch/repo/sub"
( cd "$scratch/repo/sub" && printf '%s' "$log_a" | bash "$cli" log >/dev/null 2>"$scratch/err" )
same 'a subdirectory stores into the same log file' "$(find "$logs" -type f | wc -l | tr -d ' ')" 2
git worktree add -q "$scratch/linked" -b linked 2>/dev/null
( cd "$scratch/linked" && bash "$cli" register "$url" >/dev/null 2>"$scratch/err" &&
    bash "$cli" show > "$scratch/out" 2>>"$scratch/err" )
contains 'a linked worktree sees the shared log' "$(cat "$scratch/out")" '| arXiv | 2 |'
( cd "$scratch/linked" && printf 'from linked\n' | bash "$cli" log >/dev/null 2>"$scratch/err" )
differs 'a log stored in one worktree changes the hash in the other' "$(live_hash)" "$with_log"
outcome 'so the other worktree must audit again' 3 "$(edit_status)"
git worktree remove --force "$scratch/linked"
expect 'the log outlives the removed worktree' 0 show
contains 'show still prints the shared log' "$(cat "$scratch/out")" 'from linked'
store 'the audited log is stored again' 0 "$log_a"

# A failed write leaves the stored log and its hash unchanged. Root ignores directory
# permissions, so this check only runs as an ordinary user.
if [[ "$(id -u)" != 0 ]]; then
  chmod 500 "$logs"
  store 'a write into a read-only store fails' 1 'replacement'
  chmod 700 "$logs"
  same 'the failed write left the stored log and hash unchanged' "$(live_hash)" "$with_log"
else
  printf 'SKIP read-only store checks: running as root\n'
fi

record="$logs/$(printf '%s' "$(design_id "$url")" | sha).json"
if [[ ! -f "$record" ]]; then
  report 'design A has a log record at its ID path' 1
  printf '\n%d passed, %d failed\n' "$pass" "$fail"; exit 1
fi
cp "$record" "$scratch/record"
jq -c --arg id "$(design_id "$other")" '.id = $id' "$scratch/record" > "$record"
expect 'a log record naming another design blocks' 1 check
rm "$record"; ln -s "$scratch/record" "$record"
expect 'a symlinked log blocks' 1 check
rm "$record"; mkfifo "$record"
expect 'a FIFO log blocks without waiting' 1 check
rm "$record"; cp "$scratch/record" "$record"
expect 'the restored record verifies again' 0 check
store 'an oversized log is rejected' 1 "$(printf 'x%.0s' {1..32001})"
same 'a rejected log leaves the stored one unchanged' "$(live_hash)" "$with_log"
store 'a log at the 32,000-character cap is stored' 0 "$(printf 'x%.0s' {1..32000})"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" == 0 ]]
