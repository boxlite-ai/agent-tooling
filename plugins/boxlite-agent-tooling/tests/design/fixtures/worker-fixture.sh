# Source after creating scratch. Existing validator/loop suites use a trusted fixture CLI.
# Each submitted fixture judgment traverses the real coordinator and owned subprocess.
fixture_source_plugin="$plugin"
scratch="$(cd "$scratch" && pwd -P)"
fixture_bin="$scratch/owned-worker-bin"
mkdir -p "$fixture_bin"
cp -R "$plugin" "$scratch/owned-plugin"
plugin="$scratch/owned-plugin"
cp "$fixture_source_plugin/tests/design/fixtures/owned-worker.py" "$fixture_bin/worker"
chmod +x "$fixture_bin/worker"
printf '#!/bin/sh\nexit 22\n' > "$fixture_bin/curl"
chmod +x "$fixture_bin/curl"
jq -nc --arg worker "$fixture_bin/worker" --arg curl "$fixture_bin/curl" \
  '{versions:{codex:["0.162.1"],claude:["2.1.322"]},models:{codex:"fixture",claude:"fixture"},offline_research:true,
    executables:{codex:$worker,claude:$worker,curl:$curl}}' > "$plugin/.agents/design-worker-policy.json"
fixture_cli="$scratch/owned-fixture-cli.sh"
cat > "$fixture_cli" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
if [[ "${1:-}" != verdict && "${1:-}" != advice ]]; then
  exec bash "$DESIGN_FIXTURE_PLUGIN/scripts/design-doc.sh" "$@"
fi
input="$(cat)"
run() {
  python3 -I "$DESIGN_FIXTURE_PLUGIN/scripts/design-worker.py" codex "$PWD"
}
if [[ "$1" == verdict ]]; then
  directory="$(git rev-parse --absolute-git-dir)"
  if [[ -f "$directory/agent-tooling-design-audit.json" ]]; then
    task="$(jq -r '.worker_provenance.task_id // ""' "$directory/agent-tooling-design-audit.json")"
    advised=''
    [[ ! -f "$directory/agent-tooling-design-advice.json" ]] || \
      advised="$(jq -r '.worker_provenance.verdict_task_id // ""' "$directory/agent-tooling-design-advice.json")"
    previous="$(jq -r .content_sha256 "$directory/agent-tooling-design-audit.json")"
    requested="$(jq -r .content_sha256 <<<"$input" 2>/dev/null)" || requested=''
    previous_url="$(jq -r .url "$directory/agent-tooling-design-audit.json")"
    current_url="$(jq -r .url "$directory/agent-tooling-design-doc.json")"
    if [[ -n "$task" && "$task" != "$advised" && "$previous" == "$requested" && "$previous_url" == "$current_url" ]]; then
      jq -c '{content_sha256,advice:[]}' "$directory/agent-tooling-design-audit.json" > "$DESIGN_FIXTURE_BIN/result.json"
      run >/dev/null || exit 1
    fi
  fi
else
  # Revoke previous advice so this fixture judgment receives a fresh advisor assignment.
  directory="$(git rev-parse --absolute-git-dir)"
  rm -f "$directory/agent-tooling-design-advice.json"
fi
printf '%s\n' "$input" > "$DESIGN_FIXTURE_BIN/result.json"
run || exit 1
SH
chmod +x "$fixture_cli"
export DESIGN_FIXTURE_PLUGIN="$plugin" DESIGN_FIXTURE_BIN="$fixture_bin"
