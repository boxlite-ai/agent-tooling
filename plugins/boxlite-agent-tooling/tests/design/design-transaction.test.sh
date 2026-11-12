#!/usr/bin/env bash
# Verify clone-wide exclusion through a paused production provider read.
set -euo pipefail
plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
scratch="$(mktemp -d)"
child=''
cleanup() { [[ -z "$child" ]] || kill "$child" 2>/dev/null || :; rm -rf "$scratch"; }
trap cleanup EXIT
mkdir "$scratch/repo" "$scratch/bin"
git -C "$scratch/repo" init -q -b fixture
git -C "$scratch/repo" -c core.hooksPath=/dev/null -c user.name=fixture -c user.email=fixture@example.invalid commit -qm fixture --allow-empty
git -C "$scratch/repo" worktree add -q -b secondary "$scratch/other"
cat > "$scratch/bin/gh" <<'GH'
#!/usr/bin/env bash
printf ready > "$DESIGN_TRANSACTION_FIXTURE/ready"
for (( attempt=0; attempt<200; attempt++ )); do
  [[ ! -f "$DESIGN_TRANSACTION_FIXTURE/release" ]] || break
  sleep 0.05
done
[[ -f "$DESIGN_TRANSACTION_FIXTURE/release" ]] || exit 1
jq -nc '{html_url:"https://github.com/example/project/issues/1",body:"## TL;DR\n\nSerialize the design transition.\n\n## Details\n\nRead this captured body."}'
GH
chmod +x "$scratch/bin/gh"
export PATH="$scratch/bin:$PATH" DESIGN_TRANSACTION_FIXTURE="$scratch"
bash -c 'for name in verdict-audit-state reply-summary concise-writing design-doc; do source "$1/.agents/lib/$name.sh"; done
 design_doc_transaction "$2" binding bind "$2" https://github.com/example/project/issues/1' fixture "$plugin" "$scratch/other" > "$scratch/result" 2> "$scratch/error" &
child=$!
for (( attempt=0; attempt<100; attempt++ )); do
  [[ ! -f "$scratch/ready" ]] || break
  sleep 0.05
done
[[ -f "$scratch/ready" ]] || { cat "$scratch/error"; exit 1; }
common="$(git -C "$scratch/repo" rev-parse --path-format=absolute --git-common-dir)"
# The main worktree must observe the secondary worktree's held directory lock.
perl -MFcntl=:DEFAULT,:flock -e 'sysopen(my $lock,$ARGV[0],O_RDONLY) or die $!;
  exit(flock($lock,LOCK_EX|LOCK_NB) ? 1 : 0)' "$common/agent-tooling-design-transaction"
printf release > "$scratch/release"
wait "$child"; child=''
perl -MFcntl=:DEFAULT,:flock -e 'sysopen(my $lock,$ARGV[0],O_RDONLY) or die $!;
  exit(flock($lock,LOCK_EX|LOCK_NB) ? 0 : 1)' "$common/agent-tooling-design-transaction"
printf 'RESULT: clone-wide exclusion and release passed\n'
