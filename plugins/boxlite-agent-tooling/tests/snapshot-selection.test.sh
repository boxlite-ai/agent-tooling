#!/usr/bin/env bash
# Synthetic reader checks; --benchmark [repeats] times the same fixtures.
set -euo pipefail
test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
library="$test_dir/../.agents/lib/verdict-audit-state.sh"
fixtures="$test_dir/snapshot_selection"
for dependency in bash perl jq cmp; do
  command -v "$dependency" >/dev/null || { printf 'Missing dependency: %s\n' "$dependency" >&2; exit 2; }
done
case "${1-}:$#" in
  :0) ;;
  --benchmark:1|--benchmark:2)
    [[ ${2-3} =~ ^[1-9][0-9]*$ ]] || { printf 'repeats must be positive\n' >&2; exit 2; } ;;
  *) printf 'usage: %s [--benchmark [repeats]]\n' "$0" >&2; exit 2 ;;
esac
scratch="$(mktemp -d "${TMPDIR:-/tmp}/snapshot-selection.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
export LC_ALL=C

# Replace only selection; both readers still use production parsing/encoding/I/O.
perl -0777 -e '
  my ($source, $selector) = map { open my $fh, "<", $_ or die $!; local $/; <$fh> } @ARGV;
  $source =~ s/    my \$keep_tools = scalar \@tool_entries;.*?(?=    exit 1 if length\(\$output\) \+ 1 > \$max_snapshot;)/$selector/s
    or die "selection block not found\n";
  print $source;
' "$library" "$fixtures/linear-selector.pl" > "$scratch/linear-reader.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

transcript() {
  jq -nc --argjson count "$1" --arg host "${2:-claude}" --argjson mixed "${3:-false}" \
    --arg claim "${4:-Synthetic claim: checks passed.}" '
    def assistant($text):
      {role:"assistant",content:[{type:"text",text:$text}]} |
      if $host == "claude" then {type:"assistant",message:.}
      else {type:"response_item",payload:.} end;
    {role:"user",content:"Inspect the synthetic fixture."}, assistant($claim),
    (range($count) as $i |
      (if $mixed then "证据🙂\n\t\"\\" * ([0,9,99,999,2048,5000][$i % 6]) else "x" * 700 end) as $text |
      ("tool-" + ($i|tostring)) as $id |
      (if $host == "claude" then
        if $i % 2 == 0 then
          {type:"assistant",message:{content:[{type:"tool_use",id:$id,name:"synthetic",input:{text:$text}}]}}
        else
          {type:"user",message:{content:[{type:"tool_result",tool_use_id:$id,content:$text,is_error:($i % 7 == 0)}]}}
        end
      else
        (if $i % 2 == 0 then {type:"function_call",call_id:$id,name:"synthetic",arguments:$text}
         else {type:"function_call_output",call_id:$id,output:$text} end) |
        {type:"response_item",payload:.}
      end),
      (if $i % 41 == 40 then assistant("Synthetic checkpoint \($i).") else empty end)),
    assistant("Synthetic final claim.")' > "$scratch/transcript.jsonl"
}

# Expose status separately: expected reader failures must not abort the harness.
run_reader() {
  local mode=$1 cap=$2 probe=${3:-false} reader=$library TIMEFORMAT=%3R
  [[ $mode != linear ]] || reader="$scratch/linear-reader.sh"
  rm -f "$scratch/$mode.json" "$scratch/trace"
  reader_status=0
  if { time (
    unset PERL5OPT PERL5LIB SNAPSHOT_PROBE_LOG
    if [[ $probe == true ]]; then
      export PERL5LIB="$fixtures" PERL5OPT=-MSnapshotProbe SNAPSHOT_PROBE_LOG="$scratch/trace"
    fi
    bash -c '
      # shellcheck source=../.agents/lib/verdict-audit-state.sh
      source "$1"
      verdict_audit_snapshot_final_turn "$2" "$3" 67108864 "$4"
    ' snapshot-test "$reader" "$scratch/transcript.jsonl" "$scratch/$mode.json" "$cap" \
      > "$scratch/$mode.stdout" 2> "$scratch/$mode.stderr"
  ); } 2> "$scratch/$mode.seconds"; then
    :
  else
    reader_status=$?
  fi
}

compare() {
  local cap=$1 expected=${2:-null} old_status digest
  run_reader linear "$cap"
  old_status=$reader_status
  run_reader current "$cap"
  [[ $reader_status == "$old_status" ]] || fail "status differs at cap $cap"
  cmp "$scratch/linear.stdout" "$scratch/current.stdout" || fail "stdout differs at cap $cap"
  if ((reader_status)); then
    [[ ! -e "$scratch/linear.json" && ! -e "$scratch/current.json" ]] || fail 'failure published a snapshot'
    return
  fi
  cmp "$scratch/linear.json" "$scratch/current.json" || fail "snapshot differs at cap $cap"
  if [[ -s "$scratch/current.stdout" || -s "$scratch/current.stderr" ]]; then
    cat "$scratch/current.stdout" "$scratch/current.stderr" >&2
    fail 'unexpected reader output'
  fi
  (($(wc -c < "$scratch/current.json") <= cap)) || fail "snapshot exceeds cap $cap"
  [[ $(tail -c 1 "$scratch/current.json" | od -An -tu1) -eq 10 ]] || fail 'missing final LF'
  digest="$(perl -MDigest::SHA -e 'print Digest::SHA->new(256)->addfile($ARGV[0])->hexdigest' "$scratch/transcript.jsonl")"
  jq -e --arg digest "$digest" --argjson expected "$expected" '
    .source_sha256 == $digest and
    ($expected == null or .evidence_summary.retained == $expected) and
    ([.records[] | select(.kind == "tool") | .tools[0].id] |
      . == [range(length) | "tool-\(.)"])
  ' "$scratch/current.json" >/dev/null || fail "hash/prefix mismatch at cap $cap (expected $expected)"
}

test_regression() {
  local encodings
  transcript 515
  run_reader current 262144 true
  ((reader_status == 0)) || fail '515-tool reader failed'
  jq -e '.evidence_summary.seen == 515 and .evidence_summary.omitted > 200 and (.truncated|not)' \
    "$scratch/current.json" >/dev/null || fail 'unexpected long-turn snapshot'
  encodings=$(wc -l < "$scratch/trace")
  ((encodings <= 14)) || fail "manifest encodings grew with omitted tools: $encodings > 14"
  printf 'PASS: 515-tool regression (%d encodings; limit 14)\n' "$encodings"
}

test_boundaries() {
  local host mixed count kept truncated size previous expected step cap next delta i configuration
  local sizes previews selections
  for configuration in 'claude false 12' 'codex true 12' 'claude true 101'; do
    read -r host mixed count <<< "$configuration"
    transcript "$count" "$host" "$mixed"
    run_reader linear 1 true
    ((reader_status != 0)) || fail 'cap 1 unexpectedly fits'
    sizes=() previews=() previous=0 expected=$count step=0
    while read -r kept truncated size; do
      if ((step < 3)); then previews[step]=$size; fi
      if ((step >= 2 && !truncated)); then
        ((kept == expected)) || fail 'reference skipped a prefix'
        ((previous == 0 || size < previous)) || fail 'candidate sizes are not strictly monotone'
        sizes[kept]=$size
        previous=$size expected=$((expected - 1))
      fi
      step=$((step + 1))
    done < "$scratch/trace"
    ((expected == -1)) || fail 'reference did not reach zero tools'
    selections=(0 1 9 10 90 91 99 100)
    if ((count == 12)); then
      selections=()
      for ((i=0; i<count; i++)); do selections+=("$i"); done
    fi
    for kept in "${selections[@]}"; do
      size=${sizes[$kept]}
      cap=$size
      # The serialized max_snapshot_bytes field changes its own decimal width.
      while next=$((size - 1 + ${#cap})); ((cap != next)); do cap=$next; done
      for delta in -1 0 1; do
        expected=null
        ((delta < 0)) || expected=$kept
        compare "$((cap + delta))" "$expected"
      done
    done
    for size in "${previews[@]}"; do
      cap=$size
      while next=$((size - 1 + ${#cap})); ((cap != next)); do cap=$next; done
      compare "$cap" "$count"
    done
  done
  printf 'PASS: exact byte boundaries, preview stages, and monotone candidates\n'
}

test_edges() {
  local count cap
  for count in 0 1; do
    transcript "$count"
    compare 262144 "$count"
    compare 1
    ((reader_status != 0)) || fail 'cap 1 unexpectedly fits'
  done
  transcript 10 claude false "$(jq -nr '"whole claim " * 2000')"
  compare 1000 0
  jq -e '.truncated and .records == [] and .claim_bytes > 1000' "$scratch/current.json" >/dev/null
  printf '{"role":"assistant",\n' > "$scratch/transcript.jsonl"
  compare 262144
  ((reader_status != 0)) || fail 'malformed JSON accepted'
  printf '\0\n' > "$scratch/transcript.jsonl"
  compare 262144
  ((reader_status != 0)) || fail 'NUL accepted'
  jq -nc 'range(3) as $i | {type:"function_call_output",call_id:"tool-\($i)",output:""} |
    .output = ("x" * (2047 + $i - (tojson|length)))' > "$scratch/transcript.jsonl"
  compare 262144 3
  jq -e '[.records[].tools[0]] |
    map(.payload_bytes) == [2047,2048,2049] and map(.content_truncated) == [false,false,true]' \
    "$scratch/current.json" >/dev/null || fail 'payload preview boundary changed'
  for cap in 1000 3000 5000; do compare "$cap"; done
  printf 'PASS: empty/single turns, claims overflow, invalid input, and payload cutoffs\n'
}

test_claims() {
  local host cap caps
  for host in claude codex; do
    # Preserve the former seed-264 cap samples without a random-number runtime.
    caps=(39329 72570 26313 68876 22837)
    [[ $host == claude ]] || caps=(43061 29910 2762 43961 12994)
    transcript 45 "$host" true
    for cap in 262144 1000 10000 "${caps[@]}"; do
      compare "$cap"
      if ((reader_status == 0)); then
        jq -e '.truncated or ([.records[] | select(.kind == "assistant") | .texts[]] ==
          ["Synthetic claim: checks passed.","Synthetic checkpoint 40.","Synthetic final claim."])' \
          "$scratch/current.json" >/dev/null || fail 'interleaved claims changed'
      fi
    done
  done
  printf 'PASS: interleaved claims and sampled caps in both host formats\n'
}

benchmark() {
  local repeats=$1 count cap repeat mode order
  printf '%s; %s; repeats=%s\n' "$(uname -sm)" \
    "$(perl -MJSON::PP -e 'print "$^V JSON::PP $JSON::PP::VERSION"')" "$repeats"
  for count in 352 400 472 515; do
    transcript "$count"
    for cap in 262144 4194304; do
      : > "$scratch/linear.times"; : > "$scratch/current.times"
      for ((repeat=0; repeat<repeats; repeat++)); do
        order=(linear current)
        ((repeat % 2 == 0)) || order=(current linear)
        for mode in "${order[@]}"; do
          run_reader "$mode" "$cap"
          ((reader_status == 0)) || fail "$mode benchmark failed"
          cat "$scratch/$mode.seconds" >> "$scratch/$mode.times"
        done
        cmp "$scratch/linear.json" "$scratch/current.json" || fail 'benchmark bytes differ'
      done
      jq -c --argjson cap "$cap" --slurpfile linear "$scratch/linear.times" \
        --slurpfile current "$scratch/current.times" '
        def timing: sort | {median: ((.[((length-1)/2|floor)] + .[(length/2|floor)]) / 2), min:.[0], max:.[-1]};
        {seen:.evidence_summary.seen,retained:.evidence_summary.retained,cap:$cap,
         source_bytes,identical_bytes:true,seconds:{linear:($linear|timing),current:($current|timing)}}
      ' "$scratch/current.json"
    done
  done
}

if [[ ${1-} == --benchmark ]]; then
  benchmark "${2:-3}"
else
  test_regression
  test_boundaries
  test_edges
  test_claims
fi
