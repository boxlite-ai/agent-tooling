#!/usr/bin/env bash
# Parent-supplied results cannot satisfy the real edit boundary.
set -uo pipefail
plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
# shellcheck source=../lib/assert.sh
source "$plugin/tests/lib/assert.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir "$scratch/repo" "$scratch/bin"
git -C "$scratch/repo" init -q
git -C "$scratch/repo" -c core.hooksPath=/dev/null -c commit.gpgsign=false \
  -c user.name=fixture -c user.email=fixture@example.invalid \
  commit -qm initial --allow-empty
document_url=https://github.com/example/project/issues/1
document=$'## TL;DR\n\nBind each result to its assigned worker.\n\n## Details\n\nThe gate checks the worker before accepting a result.'
jq -nc --arg url "$document_url" --arg body "$document" \
  '{html_url:$url,body:$body}' > "$scratch/document.json"
cat > "$scratch/bin/gh" <<'SH'
#!/usr/bin/env bash
cat "$DESIGN_TEST_DOCUMENT"
SH
chmod +x "$scratch/bin/gh"
export PATH="$scratch/bin:$PATH" DESIGN_TEST_DOCUMENT="$scratch/document.json"
export CLAUDE_PROJECT_DIR="$scratch/repo" PLUGIN_ROOT="$plugin"
unset GIT_DIR GIT_WORK_TREE GH_HOST GH_REPO
cd "$scratch/repo" || exit 1
repository_root="$(pwd -P)"
bash "$plugin/scripts/design-doc.sh" register "$document_url" >/dev/null || exit 1
digest="$(printf '%s' "$document" | perl -MDigest::SHA=sha256_hex -0777 -ne 'print sha256_hex($_)')"
status=0
jq -nc --arg sha "$digest" \
  '{content_sha256:$sha,verdict:"PASS",findings:[],advisories:[]}' |
  bash "$plugin/scripts/design-doc.sh" verdict > "$scratch/verdict.out" 2>&1 || status=$?
verdict_status="$status"
status=0
jq -nc --arg sha "$digest" '{content_sha256:$sha,advice:[]}' |
  bash "$plugin/scripts/design-doc.sh" advice > "$scratch/advice.out" 2>&1 || status=$?
advice_status="$status"
payload="$(jq -nc --arg cwd "$repository_root" \
  '{tool_name:"apply_patch",cwd:$cwd,session_id:"ownership-regression",
    tool_input:{command:"*** Begin Patch\n*** Update File: source.txt\n*** End Patch"}}')"
status=0
printf '%s' "$payload" | BOXLITE_HOOK_HOST=codex \
  bash "$plugin/.agents/hooks/preflight-design-doc.sh" > "$scratch/edit.out" 2>&1 || status=$?
edit_status="$status"
if [[ -n "${DESIGN_TEST_EVIDENCE_DIR:-}" ]]; then
  mkdir -p "$DESIGN_TEST_EVIDENCE_DIR"
  git_dir="$(git rev-parse --absolute-git-dir)"
  for name in agent-tooling-design-audit.json agent-tooling-design-advice.json; do
    [[ ! -f "$git_dir/$name" ]] || cp "$git_dir/$name" "$DESIGN_TEST_EVIDENCE_DIR/$name"
  done
fi
if [[ "$verdict_status" == 0 ]]; then
  bad 'parent-supplied verdict rejected' 'submission was accepted'
else
  ok 'parent-supplied verdict rejected'
fi
if [[ "$advice_status" == 0 ]]; then
  bad 'parent-supplied advice rejected' 'submission was accepted'
else
  ok 'parent-supplied advice rejected'
fi
if [[ "$edit_status" == 0 ]]; then
  bad 'parent-supplied results cannot open the edit gate' 'edit was allowed'
else
  ok 'parent-supplied results cannot open the edit gate'
fi
# Captured from the baseline's public recorders; only checkout bindings change.
git_dir="$(git rev-parse --absolute-git-dir)"
branch="$(git symbolic-ref --short HEAD)"
for kind in verdict advice; do
  destination=agent-tooling-design-audit.json
  [[ "$kind" != advice ]] || destination=agent-tooling-design-advice.json
  jq -c --arg kind "$kind" --arg root "$repository_root" --arg branch "$branch" \
    '.[$kind] | .root=$root | .branch=$branch' \
    "$plugin/tests/design/fixtures/standalone-results.json" > "$git_dir/$destination"
done
status=0
printf '%s' "$payload" | BOXLITE_HOOK_HOST=codex \
  bash "$plugin/.agents/hooks/preflight-design-doc.sh" > "$scratch/upgrade.out" 2>&1 || status=$?
if [[ "$status" == 0 ]]; then
  bad 'stored results without worker provenance require a fresh review' 'edit was allowed'
else
  ok 'stored results without worker provenance require a fresh review'
fi
assert_result
