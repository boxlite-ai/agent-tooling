#!/usr/bin/env bash
# Trusted user configuration only; callers supply verdict-audit-state.sh and jq.
audit_network_load() {
  local directory="${XDG_CONFIG_HOME:-${HOME:-}/.config}" path identity snapshot config key value
  local inherited_proxy=false lower upper
  [[ "$directory" == /* ]] || { printf 'audit-network: config directory must be absolute\n' >&2; return 2; }
  path="$directory/boxlite-agent-tooling/network.json"
  [[ -e "$path" || -L "$path" ]] || return 0
  if ! perl -e 'my @s=lstat($ARGV[0]); exit(!@s || !-f _ || -l _ || $s[4]!=$< || ($s[2]&0022) || $s[7]>8192)' "$path" \
     || ! identity="$(verdict_audit_path_identity "$path")" \
     || ! snapshot="$(verdict_audit_read_regular_state "$path" 8192 json)" \
     || ! verdict_audit_selected_identity_matches "$path" "$identity"; then
    printf 'audit-network: network.json must be a user-owned regular file, at most 8192 bytes, without group/world write access\n' >&2
    return 2
  fi
  config="${snapshot#*$'\n'}"
  if ! jq -e '
    type == "object" and all(to_entries[];
      (.key | test("^(https?|all|no)_proxy$"; "i")) and
      (.value | type == "string") and (.value | test("[\u0000-\u001f\u007f]") | not) and
      ((.key | ascii_downcase) == "no_proxy" or .value == "" or
        (.value | test("^https?://([^/@[:space:]]+@)?([A-Za-z0-9.-]+|\\[[0-9A-Fa-f:]+\\])(:[0-9]{1,5})?/?$")))) and
    ([keys[] | ascii_downcase] | length == (unique | length))
  ' <<< "$config" >/dev/null 2>&1; then
    printf 'audit-network: invalid network.json; use standard proxy keys and HTTP(S) proxy URLs\n' >&2
    return 2
  fi
  # Any explicit routing choice wins, including ALL_PROXY and intentional empty values.
  for key in http_proxy HTTP_PROXY https_proxy HTTPS_PROXY all_proxy ALL_PROXY; do
    [[ "${!key+x}" != x ]] || inherited_proxy=true
  done
  while IFS= read -r key; do
    lower="$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')"
    upper="$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')"
    if [[ "$lower" != no_proxy && "$inherited_proxy" == true ]]; then continue; fi
    [[ "${!lower+x}" != x && "${!upper+x}" != x ]] || continue
    value="$(jq -r --arg key "$key" '.[$key]' <<< "$config")" || return 2
    export "$lower=$value" "$upper=$value"
  done < <(jq -r 'keys[]' <<< "$config")
}
