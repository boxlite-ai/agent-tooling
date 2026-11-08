#!/usr/bin/env bash
# Source verdict-audit-state.sh first. Returns checked bytes and digest in
# github_body_file_text and github_body_file_sha256, or github_body_file_error.
# shellcheck disable=SC2034 # These results are read by the launchers.
github_body_file_read() {  # path, diagnostic label
  local path="$1" label="$2" snapshot
  if [[ -z "$path" || "$path" == - ]]; then
    github_body_file_error="Supply a regular $label path."
    return 1
  fi
  [[ "$path" != -* ]] || path="./$path"

  # The sentinel retains trailing LFs through command substitution.
  snapshot="$(verdict_audit_read_regular_state "$path" 24576 json && printf '.')" || {
    github_body_file_error="Cannot read $label. Use a regular text file of at most 24 KiB without NUL bytes."
    return 1
  }
  github_body_file_text="${snapshot#*$'\n'}"
  github_body_file_text="${github_body_file_text%.}"
  github_body_file_sha256="$(printf '%s' "$github_body_file_text" | perl \
    -MDigest::SHA=sha256_hex -MEncode=decode,FB_CROAK,LEAVE_SRC -e '
      binmode STDIN;
      local $/;
      my $bytes = <STDIN> // "";
      eval { decode("UTF-8", $bytes, FB_CROAK | LEAVE_SRC); 1 } or exit 1;
      print sha256_hex($bytes);
    ')" || {
    github_body_file_error="The $label must contain valid UTF-8."
    return 1
  }
}
