#!/usr/bin/env bash
# Splice workflow.md, including its skill-name reference, into a
# consumer's committed agent-instructions files, between HTML-comment markers, and
# verify the splice stays intact.
#
#   sync-guidance.sh [--check|--check-current|--force] [repo-root]
#
# Default mode SPLICES: every existing AGENTS.md / CLAUDE.md (symlinks resolved,
# duplicates collapsed to one physical file) gets the block replaced in place or
# appended after its own content; a repository with neither file gets a fresh
# AGENTS.md holding the block plus a thin CLAUDE.md bridge (`@AGENTS.md`), the
# layout every host reads natively — Codex recognizes only AGENTS.md, Claude Code
# only CLAUDE.md (inlining the import), Copilot either.
#
# --check VERIFIES without writing, for the commit and push gates: a missing,
# malformed, or hand-edited block exits nonzero (integrity is fail-closed, like a
# stale installation); a block merely behind this plugin's canonical text only
# warns (consumers float same-ref, not same-revision). Layout advice is sync-only
# so gates never nag on every commit.
# --check-current also rejects stale content for the tooling repository's CI gate.
#
# The begin marker records rev (the tooling commit that last changed the block —
# informational) and sha256 (first 12 hex of the block body's hash — load-bearing:
# a body that no longer matches its own marker was edited by hand, which is how
# the gate tells tampering from ordinary staleness). The block is byte-stable: an
# unchanged body is never rewritten, so adopting new tooling revisions produces no
# consumer diff churn.
#
# Mutating committed files is an EXPLICIT-invocation privilege: lifecycle-triggered
# installs (sync-installation.sh repair, refresh-installation.sh polling — both set
# AGENT_TOOLING_SYNC_ACTIVE=1) defer the splice, so a background refresh can never
# dirty a worktree. A target with uncommitted tracked modifications is skipped with
# a warning for the same reason; untracked files are fair game (the first install
# creates them). AGENT_TOOLING_GUIDANCE_FORCE=1 equals --force, for reaching force
# through the consumer's install.sh.
#
# Tests: bash scripts/sync-guidance.test.sh
set -euo pipefail

BEGIN_PREFIX='<!-- agent-tooling:guidance:begin '
BEGIN_RE='^<!-- agent-tooling:guidance:begin rev=[^ ]+ sha256=[0-9a-f]{12} -->$'
END_MARKER='<!-- agent-tooling:guidance:end -->'

mode=sync
require_current=0
force=0
repo_root=""
for arg in "$@"; do
  case "$arg" in
    --check) mode=check ;;
    --check-current) mode=check; require_current=1 ;;
    --force) force=1 ;;
    -*) printf 'agent-tooling: unknown option: %s\n' "$arg" >&2; exit 2 ;;
    *)
      [[ -z "$repo_root" ]] || { printf 'agent-tooling: at most one repo-root argument\n' >&2; exit 2; }
      repo_root="$arg"
      ;;
  esac
done
[[ "${AGENT_TOOLING_GUIDANCE_FORCE:-}" != "1" ]] || force=1

[[ -n "$repo_root" ]] || repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$repo_root" && -d "$repo_root" ]] || {
  printf 'agent-tooling: run inside a Git repository or pass its root\n' >&2
  exit 2
}
repo_root="$(cd "$repo_root" && pwd -P)"

plugin_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
canonical="$plugin_root/guidance/workflow.md"
[[ -r "$canonical" ]] || {
  printf 'agent-tooling: canonical guidance is missing: %s\n' "$canonical" >&2
  exit 1
}

if [[ "$mode" == sync && "${AGENT_TOOLING_SYNC_ACTIVE:-}" == "1" ]]; then
  printf 'agent-tooling: guidance splice deferred (lifecycle install); run ./.agent-tooling/install.sh to update the committed guidance block\n' >&2
  exit 0
fi

tmp_files=()
cleanup() {
  [[ ${#tmp_files[@]} -eq 0 ]] || rm -f -- ${tmp_files[@]+"${tmp_files[@]}"}
}
trap cleanup EXIT INT TERM

canonical_sha="$(shasum -a 256 "$canonical" | awk '{print $1}')"
canonical_sha12="${canonical_sha:0:12}"
tooling_rev="$(git -C "$plugin_root" rev-parse --short=12 HEAD 2>/dev/null || echo unversioned)"
# The stamp names the revision whose workflow supplies the block.
# That holds for every production splice, which runs from an
# immutable fetched checkout — but not when someone splices from a working tree whose
# canonical is modified, where the stamp would name a revision that never held this
# text. Say so in the stamp rather than letting it quietly lie; the next clean splice
# drops the suffix. (Marker parsing is unaffected: rev is matched as [^ ]+.)
#
# Sync-only: the stamp is written here, and only a splice can record a misleading
# one. Running it in --check too would put this warning in front of every commit
# made in the tooling repository, where a modified canonical is the normal state.
if [[ "$mode" == sync && "$tooling_rev" != unversioned ]] \
   && [[ -n "$(git -C "$plugin_root" status --porcelain -- guidance/workflow.md 2>/dev/null)" ]]; then
  tooling_rev="$tooling_rev-dirty"
  printf 'agent-tooling: canonical guidance is modified in %s; stamping %s\n' \
    "$plugin_root" "$tooling_rev" >&2
fi

# mktemp creates 0600, and mv carries that mode to the destination — so every splice
# would silently turn a committed, group/world-readable instructions file into an
# owner-only one. Git hides it (it records only the exec bit), but CI runners,
# containers, and any other uid that reads these files do not. Stamp the temp file
# with the mode of what it replaces, or the umask default when creating.
#
# GNU `-c` is tried first because it FAILS on BSD/macOS stat, while BSD's `-f` means
# "filesystem status" to GNU stat and would succeed with the wrong answer.
file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null
}

# Fails closed, and deliberately: every failure here ends with mv giving the
# destination mktemp's 0600 — the exact defect this function exists to prevent.
# Guessing the umask default for a file that already exists is just as wrong,
# since a consumer may keep its instructions at 640 on purpose.
set_target_mode() {  # $1 = temp file, $2 = destination (need not exist yet)
  local mode
  if [[ -e "$2" ]]; then
    mode="$(file_mode "$2")" || mode=""
    [[ -n "$mode" ]] || {
      printf 'agent-tooling: cannot read the mode of %s; refusing to replace it\n' "$2" >&2
      return 1
    }
  else
    mode="$(printf '%o' "$(( 0666 & ~0$(umask) ))")"
  fi
  chmod "$mode" "$1" || {
    printf 'agent-tooling: cannot set mode %s for %s\n' "$mode" "$2" >&2
    return 1
  }
}

# Presentation is separate from content. The blank line after the begin marker is
# required by Markdown composition, not by us: a formatter treats an HTML comment
# butted against the following block as a mistake, and being formatter-clean is
# what keeps the block out of a consumer's CI failures. Integrity ignores these
# separators — classify_target trims the body's blank edges before hashing — so
# the recorded sha256 stays the hash of the rendered guidance itself.
render_block() {  # $1 = revision to stamp; emits the full marker-wrapped block
  printf '%srev=%s sha256=%s -->\n\n' "$BEGIN_PREFIX" "$1" "$canonical_sha12"
  cat "$canonical"
  printf '%s\n' "$END_MARKER"
}

write_block() {  # the block as it should be written now
  render_block "$tooling_rev"
}

resolve_file() {  # follow symlinks (bounded), print the physical path of a regular file
  local p="$1" i=0 link dir
  while [[ -L "$p" ]]; do
    i=$((i + 1)); [[ "$i" -le 8 ]] || return 1
    link="$(readlink "$p")" || return 1
    case "$link" in /*) p="$link" ;; *) p="$(dirname "$p")/$link" ;; esac
  done
  [[ -f "$p" ]] || return 1
  dir="$(cd "$(dirname "$p")" && pwd -P)" || return 1
  printf '%s/%s' "$dir" "$(basename "$p")"
}

# Collect the physical instructions files. Entries that exist but cannot be
# managed (broken symlink, resolution outside the repository) are warned about
# and, if nothing manageable remains, fail closed — an unmanageable layout must
# not read as "nothing to do".
targets=()
had_entries=0
agents_real=""
for name in AGENTS.md CLAUDE.md; do
  path="$repo_root/$name"
  [[ -e "$path" || -L "$path" ]] || continue
  had_entries=1
  if ! real="$(resolve_file "$path")"; then
    printf 'agent-tooling: %s exists but does not resolve to a regular file\n' "$name" >&2
    continue
  fi
  case "$real" in
    "$repo_root"/*) ;;
    *)
      printf 'agent-tooling: %s resolves outside the repository (%s); not managed\n' "$name" "$real" >&2
      continue
      ;;
  esac
  dup=0
  for t in ${targets[@]+"${targets[@]}"}; do [[ "$t" != "$real" ]] || dup=1; done
  [[ "$dup" == 0 ]] || continue
  # A CLAUDE.md that imports a managed AGENTS.md is a bridge: Claude Code inlines
  # the import, so the block reaches it through AGENTS.md — a second copy here
  # would make Claude read the guidance twice. Bridges are exempt in both modes.
  if [[ "$name" == CLAUDE.md && -n "$agents_real" ]] \
     && grep -qE '^@AGENTS\.md([[:space:]]|$)' "$real"; then
    continue
  fi
  targets+=("$real")
  [[ "$name" != AGENTS.md ]] || agents_real="$real"
done

rc=0
fail() { printf 'agent-tooling: %s\n' "$1" >&2; rc=1; }
warn() { printf 'agent-tooling: %s\n' "$1" >&2; }

if [[ "$had_entries" == 1 && ${#targets[@]} -eq 0 ]]; then
  fail 'no manageable instructions file (see above); fix the layout, then rerun ./.agent-tooling/install.sh'
  exit "$rc"
fi

created_fresh=""
if [[ ${#targets[@]} -eq 0 ]]; then
  if [[ "$mode" == check ]]; then
    fail 'no AGENTS.md or CLAUDE.md carries the guidance block; run ./.agent-tooling/install.sh'
    exit "$rc"
  fi
  agents_file="$repo_root/AGENTS.md"
  tmp="$(mktemp "$repo_root/.agent-tooling-guidance.XXXXXX")"
  tmp_files+=("$tmp")
  write_block > "$tmp"
  set_target_mode "$tmp" "$agents_file" || exit 1
  mv "$tmp" "$agents_file"
  printf 'agent-tooling: created AGENTS.md with the guidance block (rev %s)\n' "$tooling_rev"
  targets=("$agents_file")
  created_fresh="$agents_file"
fi

# classify_target: sets block_state (missing|current|stale|hand-edited|malformed) and
# block_rev (the marker's recorded revision, empty when there is no parsable marker).
classify_target() {
  local f="$1" begins ends begin_ln end_ln begin_line marker_sha inner_sha inner_tmp
  block_state=""
  block_rev=""
  begins="$(grep -c "^$BEGIN_PREFIX" "$f")" || true
  ends="$(grep -cxF "$END_MARKER" "$f")" || true
  if [[ "$begins" == 0 && "$ends" == 0 ]]; then
    block_state=missing
    return 0
  fi
  if [[ "$begins" != 1 || "$ends" != 1 ]]; then
    block_state=malformed
    return 0
  fi
  begin_ln="$(awk -v p="$BEGIN_PREFIX" 'index($0, p) == 1 {print NR; exit}' "$f")"
  end_ln="$(awk -v m="$END_MARKER" '$0 == m {print NR; exit}' "$f")"
  if [[ -z "$begin_ln" || -z "$end_ln" || "$begin_ln" -ge "$end_ln" ]]; then
    block_state=malformed
    return 0
  fi
  inner_tmp="$(mktemp "${TMPDIR:-/tmp}/agent-tooling-guidance.XXXXXX")"
  tmp_files+=("$inner_tmp")
  # Content is the body with its blank edges trimmed, so the separators that
  # Markdown composition requires never read as a hand-edit or as staleness.
  awk -v s="$begin_ln" -v e="$end_ln" '
    NR > s && NR < e { line[++n] = $0; if ($0 ~ /[^[:space:]]/) { if (!first) first = n; last = n } }
    END { for (i = first; i <= last; i++) print line[i] }' "$f" > "$inner_tmp"
  begin_line="$(sed -n "${begin_ln}p" "$f")"
  if ! printf '%s\n' "$begin_line" | grep -qE "$BEGIN_RE"; then
    block_state=hand-edited
    return 0
  fi
  block_rev="$(printf '%s\n' "$begin_line" | sed -E 's/.* rev=([^ ]+) sha256=.*/\1/')"
  marker_sha="$(printf '%s\n' "$begin_line" | sed -E 's/.* sha256=([0-9a-f]{12}) -->$/\1/')"
  inner_sha="$(shasum -a 256 "$inner_tmp" | awk '{print $1}')"
  if [[ "$marker_sha" != "${inner_sha:0:12}" ]]; then
    block_state=hand-edited
    return 0
  fi
  if ! cmp -s "$inner_tmp" "$canonical"; then
    block_state=stale
    return 0
  fi
  # Right content, possibly rendered by an older layout. Compare against what
  # would be written now, holding the recorded rev fixed so a mere revision bump
  # still produces no write — byte-stability applies to layout too, and without
  # this a presentation fix could never reach a block whose content matches.
  local actual_tmp expected_tmp
  actual_tmp="$(mktemp "${TMPDIR:-/tmp}/agent-tooling-guidance.XXXXXX")"
  expected_tmp="$(mktemp "${TMPDIR:-/tmp}/agent-tooling-guidance.XXXXXX")"
  tmp_files+=("$actual_tmp" "$expected_tmp")
  awk -v s="$begin_ln" -v e="$end_ln" 'NR >= s && NR <= e' "$f" > "$actual_tmp"
  render_block "$block_rev" > "$expected_tmp"
  if cmp -s "$actual_tmp" "$expected_tmp"; then
    block_state=current
  else
    block_state=stale
  fi
}

splice_target() {  # replace or append the block in $1; $2 = block_state
  local f="$1" state="$2" rel tmp blk status
  rel="${f#"$repo_root"/}"
  status="$(git -C "$repo_root" status --porcelain -- "$rel" 2>/dev/null | head -n1)"
  if [[ -n "$status" && "${status:0:2}" != '??' && "$force" != 1 ]]; then
    warn "$rel has uncommitted changes; guidance splice skipped — commit or stash them, then rerun ./.agent-tooling/install.sh"
    return 0
  fi
  tmp="$(mktemp "$(dirname "$f")/.agent-tooling-guidance.XXXXXX")"
  tmp_files+=("$tmp")
  if [[ "$state" == missing ]]; then
    if [[ -s "$f" ]]; then
      # Drop trailing blank lines, then separate with exactly one. Appending blindly
      # stacks a blank line per strip-and-resplice cycle, and since the splicer never
      # rewrites an up-to-date block, whatever lands here is what consumers commit.
      # awk also terminates a final line that had no newline of its own.
      awk '{ line[NR] = $0; if ($0 ~ /[^[:space:]]/) last = NR }
           END { for (i = 1; i <= last; i++) print line[i] }' "$f" > "$tmp"
      printf '\n' >> "$tmp"
    fi
    write_block >> "$tmp"
  else
    blk="$(mktemp "${TMPDIR:-/tmp}/agent-tooling-guidance.XXXXXX")"
    tmp_files+=("$blk")
    write_block > "$blk"
    awk -v p="$BEGIN_PREFIX" -v m="$END_MARKER" -v blk="$blk" '
      index($0, p) == 1 { skip = 1; while ((getline line < blk) > 0) print line; close(blk); next }
      $0 == m           { skip = 0; next }
      skip              { next }
                        { print }
    ' "$f" > "$tmp"
  fi
  set_target_mode "$tmp" "$f" || return 1
  mv "$tmp" "$f"
  printf 'agent-tooling: guidance updated in %s (rev %s)\n' "$rel" "$tooling_rev"
}

for f in "${targets[@]}"; do
  [[ "$f" != "$created_fresh" ]] || continue  # just written; already reported
  rel="${f#"$repo_root"/}"
  classify_target "$f"
  case "$mode:$block_state" in
    check:current) ;;
    check:stale)
      if [[ "$require_current" == 1 ]]; then
        fail "guidance block in $rel is behind the adopted tooling revision; run ./.agent-tooling/install.sh"
      else
        warn "guidance block in $rel is behind the adopted tooling revision; run ./.agent-tooling/install.sh"
      fi
      ;;
    check:missing)
      fail "guidance block is missing from $rel; run ./.agent-tooling/install.sh"
      ;;
    check:malformed)
      fail "guidance markers in $rel are malformed (exactly one begin and one end, in order); restore them, then run ./.agent-tooling/install.sh"
      ;;
    check:hand-edited)
      fail "guidance block in $rel was edited by hand; it is managed by boxlite-ai/agent-tooling — revert the edit (or apply it in the tooling repo), then run ./.agent-tooling/install.sh"
      ;;
    sync:current)
      # Byte-stability says matching content is never rewritten — with one exception.
      # A `-dirty` stamp names a revision that never held this text, and since the
      # body already matches, no later content change is guaranteed to ever correct
      # it. Refresh the marker once, now that the canonical is committed; a normal
      # stamp still produces no write, so consumers keep their churn-free diffs.
      if [[ "$block_rev" == *-dirty && "$tooling_rev" != *-dirty ]]; then
        splice_target "$f" stale
      else
        printf 'agent-tooling: guidance in %s is up to date\n' "$rel"
      fi
      ;;
    sync:malformed)
      fail "guidance markers in $rel are malformed (exactly one begin and one end, in order); restore them by hand, then rerun"
      ;;
    sync:hand-edited)
      if [[ "$force" == 1 ]]; then
        splice_target "$f" hand-edited
      else
        fail "guidance block in $rel was edited by hand; revert the edit (or apply it in the tooling repo), or force the overwrite with AGENT_TOOLING_GUIDANCE_FORCE=1 ./.agent-tooling/install.sh"
      fi
      ;;
    sync:missing|sync:stale)
      splice_target "$f" "$block_state"
      ;;
  esac
done

# Layout advice — sync mode only, so the gates never nag on every commit.
if [[ "$mode" == sync ]]; then
  if [[ ! -e "$repo_root/CLAUDE.md" && ! -L "$repo_root/CLAUDE.md" ]]; then
    tmp="$(mktemp "$repo_root/.agent-tooling-guidance.XXXXXX")"
    tmp_files+=("$tmp")
    {
      printf '@AGENTS.md\n\n'
      printf '<!-- Claude Code inlines AGENTS.md through the import above; add Claude-specific\n'
      printf '     instructions below this line. Other hosts read AGENTS.md directly. -->\n'
    } > "$tmp"
    set_target_mode "$tmp" "$repo_root/CLAUDE.md" || exit 1
    mv "$tmp" "$repo_root/CLAUDE.md"
    printf 'agent-tooling: created the CLAUDE.md bridge (@AGENTS.md)\n'
  fi
  if [[ ! -e "$repo_root/AGENTS.md" && ! -L "$repo_root/AGENTS.md" ]]; then
    warn 'no AGENTS.md: Codex reads only AGENTS.md by default — consider making it the canonical instructions file (CLAUDE.md as an @AGENTS.md bridge or symlink)'
  fi
fi

exit "$rc"
