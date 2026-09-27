#!/usr/bin/env bash
set -euo pipefail
library="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pr-watch-schedule.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
before="$PWD:$-"
# shellcheck source=pr-watch-schedule.sh
source "$library" > "$scratch/source.out"
[[ "$before" == "$PWD:$-" && ! -s "$scratch/source.out" ]] || exit 1
export SCHEDULE_TEST_LOG="$scratch/calls"
cat > "$scratch/session.sh" <<'EOF'
#!/usr/bin/env bash
[[ $# == 5 && $1 == --keepalive && $2 == --branch && $4 == --pr ]] || exit 2
printf '%s\n' "$3" >> "$SCHEDULE_TEST_LOG"
case "$3" in
  busy) exit 75 ;;
  broken) exit 1 ;;
  stopped) printf '{"status":"stopped"}\n' ;;
  *) printf '{"status":"healthy"}\n' ;;
esac
EOF
targets="$(jq -nc --arg worktree "$scratch" \
  '["busy","stopped","$(touch should-not-exist)"] | map({worktree:$worktree,branch:.})')"
result="$(pr_watch_schedule_tick "$scratch/session.sh" "$targets")"
[[ "$result" == '{"active":2,"stopped":1}' && ! -e "$scratch/should-not-exist" ]] || exit 1
[[ "$(wc -l < "$scratch/calls" | tr -d ' ')" == 3 ]] || exit 1
printf 'PASS: library is inert; busy leases defer and target strings remain data\n'

for invalid in '[]' '[{}]' "{} $targets" \
  "$(jq '.[1].branch=42' <<< "$targets")" \
  "$(jq '.[1].pr=false' <<< "$targets")" \
  "$(jq '.[1].worktree="relative"' <<< "$targets")" \
  "$(jq '[range(33) as $i | .[0]]' <<< "$targets")"; do
  : > "$scratch/calls"
  if pr_watch_schedule_tick "$scratch/session.sh" "$invalid" > "$scratch/out" 2> "$scratch/err"; then exit 1; else rc=$?; fi
  [[ "$rc" == 2 && ! -s "$scratch/out" && ! -s "$scratch/calls" && -s "$scratch/err" ]] || exit 1
done
printf 'PASS: all targets validate before any reconciliation\n'

targets="$(jq '.[0].branch="broken"' <<< "$targets")"
if pr_watch_schedule_tick "$scratch/session.sh" "$targets" > "$scratch/out" 2> "$scratch/err"; then exit 1; else rc=$?; fi
[[ "$rc" == 1 && ! -s "$scratch/out" && -s "$scratch/err" ]] || exit 1
[[ "$(wc -l < "$scratch/calls" | tr -d ' ')" == 3 ]] || exit 1
printf 'PASS: failed targets remain errors while independent targets still run\n'
