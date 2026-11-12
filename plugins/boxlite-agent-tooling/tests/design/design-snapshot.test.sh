#!/usr/bin/env bash
# A verified provider read and the displayed snapshot must be the same response.
set -euo pipefail
plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
# shellcheck source=../lib/assert.sh
source "$plugin/tests/lib/assert.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir "$scratch/bin" "$scratch/repo"
git -C "$scratch/repo" init -q
git -C "$scratch/repo" -c core.hooksPath=/dev/null -c user.name=fixture \
  -c user.email=fixture@example.invalid commit -qm fixture --allow-empty
body=$'## TL;DR\n\nReview the captured design.\n\n## Details\n\nUse this exact response.'
url=https://github.com/example/project/issues/1
jq -nc --arg body "$body" --arg url "$url" '{body:$body,html_url:$url}' > "$scratch/first.json"
jq -nc --arg url "$url" '{body:"Unverified replacement",html_url:$url}' > "$scratch/second.json"
printf '0\n' > "$scratch/count"
cat > "$scratch/bin/gh" <<'SH'
#!/usr/bin/env bash
count="$(cat "$DESIGN_SNAPSHOT_FIXTURE/count")"
printf '%s\n' "$((count+1))" > "$DESIGN_SNAPSHOT_FIXTURE/count"
if [[ "$count" == 0 ]]; then cat "$DESIGN_SNAPSHOT_FIXTURE/first.json"
else cat "$DESIGN_SNAPSHOT_FIXTURE/second.json"; fi
SH
chmod +x "$scratch/bin/gh"
export PATH="$scratch/bin:$PATH" DESIGN_SNAPSHOT_FIXTURE="$scratch"
unset GIT_DIR GIT_WORK_TREE GH_REPO GH_HOST
cd "$scratch/repo"
bash "$plugin/scripts/design-doc.sh" register "$url" >/dev/null
printf '0\n' > "$scratch/count"
shown="$(bash "$plugin/scripts/design-doc.sh" show)"
check_eq 'show returns the provider body it verified' "$shown" "$body"
check_eq 'show captures the provider exactly once' "$(cat "$scratch/count")" 1
assert_result
