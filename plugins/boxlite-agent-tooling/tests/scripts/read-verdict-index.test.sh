#!/usr/bin/env bash
set -euo pipefail
scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../scripts" && pwd -P)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
repo="$scratch/repo with spaces"
state="$repo/.agents/state"
source_file="$scratch/native transcript.jsonl"
session='fixture/../session'
mkdir -p "$state"
git -C "$repo" init -q
scope="$(printf '%s' "$session" | git -C "$repo" hash-object --stdin)"
index="$state/last-verdict-index.json.git-$scope"
printf 'earlier turn\n' > "$source_file"
end="$(wc -c < "$source_file" | tr -d ' ')"
identity="$(perl -e 'my @s=stat($ARGV[0]); print "$s[0]:$s[1]"' "$source_file")"
sha="$(perl -MDigest::SHA -e 'print Digest::SHA->new(256)->addfile($ARGV[0])->hexdigest' "$source_file")"
valid="$(jq -nc --arg inode "$identity" --arg sha "$sha" --argjson end "$end" '
  {version:1,generation:"42-100-12",message_id:"cksum-22-11",turn_id:"turn-1",
   native_range:{device_inode:$inode,start_byte:0,end_byte:$end,sha256:$sha}}')"
passed=0

expect() {
  local label="$1" expected_status="$2" expected_output="$3" result status=0
  shift 3
  result="$(bash "$scripts/read-verdict-index.sh" "$@" 2>"$scratch/stderr")" || status=$?
  if [[ -e "$scratch/perl-option-marker" ]]; then
    printf 'FAIL %s: transcript filename executed as Perl code\n' "$label" >&2
    exit 1
  fi
  if [[ "$status" != "$expected_status" || "$result" != "$expected_output" || -s "$scratch/stderr" ]]; then
    printf 'FAIL %s: status=%s output=%q\n' "$label" "$status" "$result" >&2
    cat "$scratch/stderr" >&2
    exit 1
  fi
  passed=$((passed + 1))
  printf 'PASS %s\n' "$label"
}

ignore() {
  expect "$1" 1 "" "$repo" "$session" "$source_file"
}

ignore 'missing index'
printf '%s\n' "$valid" > "$index"
ignore 'checkpoint at EOF'
printf 'current turn\n' >> "$source_file"
expect 'append to the same transcript' 0 "$end" "$repo" "$session" "$source_file"
option_source='-eBEGIN{open my $marker,">perl-option-marker";close $marker}'
mv "$source_file" "$scratch/$option_source"
pushd "$scratch" >/dev/null
expect 'option-shaped filename' 0 "$end" "$repo" "$session" "$option_source"
popd >/dev/null
mv "$scratch/$option_source" "$source_file"
expect 'missing parent session' 1 "" "$repo" "" "$source_file"
expect 'different parent session' 1 "" "$repo" 'different-session' "$source_file"
expect 'missing repository' 1 "" "$scratch/missing" "$session" "$source_file"
expect 'missing transcript' 1 "" "$repo" "$session" "$scratch/missing"
expect 'directory transcript' 1 "" "$repo" "$session" "$scratch"
mkfifo "$scratch/source-fifo"
expect 'FIFO transcript' 1 "" "$repo" "$session" "$scratch/source-fifo"
ln -s "$source_file" "$scratch/source-link"
expect 'symlink transcript' 1 "" "$repo" "$session" "$scratch/source-link"

for rule in \
    'del(.native_range)' \
    'del(.generation)' \
    '.version = 2' \
    '.extra = true' \
    '.generation = "broken"' \
    '.message_id = "cksum-2-1\n"' \
    '.turn_id = null' \
    '.turn_id += "\nsecond line"' \
    '.native_range = []' \
    '.native_range.extra = 1' \
    '.native_range.start_byte = -1' \
    '.native_range.start_byte = 0.5' \
    '.native_range.start_byte = .native_range.end_byte' \
    '.native_range.start_byte = .native_range.end_byte + 1' \
    '.native_range.end_byte |= tostring' \
    '.native_range.end_byte = 9007199254740993' \
    '.native_range.sha256 = "broken"' \
    '.native_range.device_inode = "1:2"'; do
  jq -c "$rule" <<<"$valid" > "$index"
  ignore "$rule"
done

for body in '' '{invalid' "$valid $valid" "{\"version\":2,${valid#\{}"; do
  printf '%s\n' "$body" > "$index"
  ignore 'empty, malformed, repeated, or duplicate-key record'
done
printf '%s\n\n' "$valid" > "$index"
ignore 'extra record delimiter'
printf '%s\n%4096s' "$valid" '' > "$index"
ignore 'oversized file'
rm "$index"
mkdir "$index"
ignore 'directory index'
rmdir "$index"
mkfifo "$index"
ignore 'FIFO index'
rm "$index"
printf '%s\n' "$valid" > "$scratch/alternate-index"
ln -s "$scratch/alternate-index" "$index"
ignore 'symlink index'
rm "$index"
jq -c 'del(.turn_id)' <<<"$valid" > "$index"
expect 'optional turn ID absent' 0 "$end" "$repo" "$session" "$source_file"

mv "$state" "$scratch/alternate-state"
ln -s "$scratch/alternate-state" "$state"
ignore 'symlink state directory'
rm "$state"
mv "$scratch/alternate-state" "$state"
mv "$source_file" "$scratch/prior-source"
cp "$scratch/prior-source" "$source_file"
ignore 'replacement transcript with identical bytes'
mv "$scratch/prior-source" "$source_file"
printf 'short\n' > "$source_file"
ignore 'same-inode truncation below the checkpoint'
printf '%d passed, 0 failed\n' "$passed"
