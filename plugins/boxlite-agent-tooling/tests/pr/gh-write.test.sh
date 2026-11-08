#!/usr/bin/env bash
set -euo pipefail

plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
scratch="$(mktemp -d)"
trap 'rm -rf -- "$scratch"' EXIT
mkdir "$scratch/bin"
export PATH="$scratch/bin:$PATH"
export STUB_ARGV="$scratch/argv" STUB_BODY="$scratch/received"
export BODY_SOURCE="$scratch/body with spaces.md" BODY_REPLACEMENT="$scratch/replacement"
cat > "$scratch/bin/gh" <<'GH'
#!/usr/bin/env bash
set -eu
printf '%s\0' "$@" >> "$STUB_ARGV"
if [[ -f "$BODY_REPLACEMENT" ]]; then
  mv -- "$BODY_REPLACEMENT" "$BODY_SOURCE"
fi
cat > "$STUB_BODY"
exit "${GH_STUB_STATUS:-0}"
GH
chmod +x "$scratch/bin/gh"

launch() { bash "$plugin/scripts/gh-write.sh" "$@"; }
fail() { printf 'gh-write: %s\n' "$*" >&2; exit 1; }
deny() {
  local expected="$1"
  shift
  rm -f -- "$STUB_ARGV"
  if launch "$@" >"$scratch/stdout" 2>"$scratch/stderr"; then fail "unexpected success for $1 $2"; fi
  [[ ! -e "$STUB_ARGV" && ! -s "$scratch/stdout" ]] || fail 'denial reached the CLI'
  grep -Fq -- "$expected" "$scratch/stderr" || { cat "$scratch/stderr" >&2; fail 'wrong diagnostic'; }
}
check_write() {  # group operation flag [metadata and operands]
  local group="$1" operation="$2" flag="$3" stdin_flag=--body-file=-
  shift 3
  [[ "$group" != release ]] || stdin_flag=--notes-file=-
  rm -f -- "$STUB_ARGV"
  cp "$scratch/approved" "$BODY_SOURCE"
  launch "$group" "$operation" "$flag" "$BODY_SOURCE" "$@"
  printf '%s\0' "$group" "$operation" "$stdin_flag" "$@" > "$scratch/expected-argv"
  cmp -s "$scratch/expected-argv" "$STUB_ARGV" || fail "wrong CLI call for $group $operation"
  cmp -s "$scratch/approved" "$STUB_BODY" || fail "changed body for $group $operation"
}

{
  printf '## TL;DR\r\n\r\nRetry failed writes once.\r\n\r\n## How it works\n\n'
  printf '~~~text\n保留 byte boundaries.\n'
  perl -e 'print "x" x 20300'
  printf '\n~~~\n\n\n'
} > "$scratch/approved"
printf 'replaced\n' > "$BODY_REPLACEMENT"
check_write issue edit --body-file 42 --title 'Preserve checked text'
[[ "$(cat "$BODY_SOURCE")" == replaced ]] || fail 'source was never replaced'
check_write issue create -F --title 'Create an issue'
check_write issue comment --body-file 42 --edit-last
check_write pr comment -F 42
check_write pr review --body-file 42 --comment
check_write release create --notes-file --draft -- v1.2.3
check_write release edit -F v1.2.3 --draft=false

cp "$scratch/approved" "$BODY_SOURCE"
launch issue edit "--body-file=$BODY_SOURCE" 42
cmp -s "$scratch/approved" "$STUB_BODY" || fail 'equals flag changed bytes'
launch release edit "-F$BODY_SOURCE" v1.2.3
cmp -s "$scratch/approved" "$STUB_BODY" || fail 'attached flag changed bytes'
perl -0777 -pe 'my $extra = 24576 - length; s/x{100}/"x" x (100 + $extra)/e' \
  < "$scratch/approved" > "$scratch/limit"
[[ "$(wc -c < "$scratch/limit" | tr -d ' ')" == 24576 ]] || fail 'wrong boundary fixture size'
launch issue edit --body-file "$scratch/limit" 42
cmp -s "$scratch/limit" "$STUB_BODY" || fail 'maximum-size input changed bytes'
status=0
GH_STUB_STATUS=17 launch issue edit --body-file "$BODY_SOURCE" 42 || status=$?
[[ "$status" == 17 ]] || fail 'CLI failure status was not propagated'

deny 'one tag' release create --notes-file "$BODY_SOURCE" v1.2.3 "$scratch/private.zip"
deny 'one tag' release create --notes-file "$BODY_SOURCE" -- v1.2.3 "$scratch/private.zip"
deny 'one checked text source' issue edit --body-file "$BODY_SOURCE" 42 --body duplicate
deny 'one checked text source' pr review -F "$BODY_SOURCE" 42 --comment --body-file=other
deny 'inspectable' issue create -F "$BODY_SOURCE" --title example --template other
deny 'inspectable' release create -F "$BODY_SOURCE" v1.2.3 --generate-notes
deny 'delete' issue comment -F "$BODY_SOURCE" 42 --delete-last --yes
deny 'Use gh-write.sh' pr create -F "$BODY_SOURCE"
deny 'regular' issue edit -F - 42
ln -s "$BODY_SOURCE" "$scratch/link"
mkfifo "$scratch/fifo"
deny 'regular' issue edit -F "$scratch/link" 42
deny 'regular' issue edit -F "$scratch/fifo" 42
printf 'one\0two' > "$scratch/nul"
deny 'NUL' issue edit -F "$scratch/nul" 42
printf '\377' > "$scratch/invalid"
deny 'UTF-8' issue edit -F "$scratch/invalid" 42
perl -e 'print "x" x 24577' > "$scratch/oversized"
deny '24 KiB' issue edit -F "$scratch/oversized" 42
printf '%s\n' 'Per our private conversation, publish this.' > "$scratch/private"
deny 'private context' issue edit -F "$scratch/private" 42
printf '%s\n' 'Missing summary.' > "$scratch/bad"
deny 'TL;DR' issue edit -F "$scratch/bad" 42

hook="$plugin/.agents/hooks/preflight-pr-review.sh"
reason_for() {
  jq -nc --arg cmd "$1" '{tool_input:{command:$cmd}}' | bash "$hook" \
    | jq -er '.hookSpecificOutput.permissionDecisionReason'
}
inline_error="$(reason_for "gh issue edit 42 --body 'Missing summary.'")"
file_error="$(cat "$scratch/stderr")"
[[ "$file_error" == "$inline_error" ]] || fail 'file and inline diagnostics differ'
raw_error="$(reason_for 'gh issue edit 42 --body-file approved.md')"
[[ "$raw_error" == *'must be inspectable'* ]] || fail 'raw file call was authorized'
printf 'gh-write: seven operations, exact bytes, and fail-closed guards passed\n'
