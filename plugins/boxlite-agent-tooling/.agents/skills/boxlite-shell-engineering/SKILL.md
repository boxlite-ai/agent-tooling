---
name: boxlite-shell-engineering
description: Engineer Bash and POSIX shell scripts, hooks, and gates with explicit I/O and failure contracts.
---

# BoxLite Shell Engineering

Apply `boxlite-clean-code` for general design and test quality.
Repository requirements and caller contracts govern conflicting upstream conventions.

Treat shell as a small program, not a command transcript. Preserve host-facing
stdin, stdout, stderr, and exit codes before restructuring a hook.

## Contract and style

- Establish Bash or POSIX `sh`, minimum interpreter version, supported operating
  systems, and required utilities; match the shebang and avoid accidental Bashisms.
- Read Google's guide for Bash; read Git's shell section for portable `sh`.
  Use the [reference index](references/index.md) for complete sources and caveats;
  load other guides only for relevant topics.
- Follow existing formatting during narrow edits. Without a project convention,
  use Google's two-space Bash style; configure `shfmt` for the chosen dialect.
- Preserve argument boundaries with Bash arrays or POSIX `"$@"`; avoid command
  strings, unquoted expansion, and parsing `ls` output.
- Check the oldest supported interpreter and GNU/BSD utility differences.
  For Windows, name and verify the intended shell environment; linting proves no host compatibility.

## Design

- Keep the executable as the composition root: dependency checks, library loading,
  input parsing, then one command/event dispatch.
- Put cohesive reusable behavior in the repository's library directory
  (`.agents/lib/` here). Sourced libraries have no top-level mutation, exit, stdin read, or output.
- Namespace exported functions and module variables; Bash has one global function table.
- Give lifecycle transitions one serialization owner. Do not encode state machines as
  cooperating booleans or make callers assemble lock order.
- Pass cross-module values explicitly. Avoid dynamic dispatch, dynamic function names,
  `eval`, inheritance emulation, and executable text built from data.

## Boundaries and failure

- For this plugin, reuse `verdict-audit-state.sh` for bounded reads, atomic writes,
  inode checks, and state paths; do not recreate security-sensitive file primitives.
- Use `printf` for machine output, quote expansions unless documented splitting is
  intended, and pass data through arguments or authenticated encoding.
- Preserve explicit failure propagation. Before adding `set -e`, audit every conditional,
  pipeline, command substitution, and expected nonzero branch. Preserve intentional
  `set -uo pipefail` behavior.
- Separate `local` declarations from command substitutions when checking the
  command's status; declaration builtins can hide failure.
- Check required commands at the executable boundary; libraries document assumptions.
- Keep cleanup recoverable and narrow. Never recursively delete runtime state.

## Concurrency review

Draw start, escalation, selection, completion, new-prompt, and teardown as interleaved timelines.

- Identify each state-file owner and the lock covering every check/write pair.
- Bound locks, reads, waits, receipt counts, and leases.
- Test regular files, symlinks, FIFOs, directories, stale/malformed records, replacement generations, and replayed notifications as distinct inputs.

## Verify

1. Exercise stdin, stdout, stderr, and exit behavior at the public script boundary.
2. Run `bash -n` on changed Bash files; use the intended `sh -n` for POSIX files.
3. Run `shellcheck -x` when available; annotate every dynamic source with a nearby
   `# shellcheck source=` directive. Explain narrow diagnostic suppressions.
4. Run the focused hook suite, host parity, then all plugin `*.test.sh` suites.
5. Run the plugin's `scripts/sync-guidance.sh --check <repo-root>` and `git diff --check`.

Report executed checks, unavailable tools, and unverified host/platform combinations.

## References

Full snapshots, license notices, source revisions, and refresh instructions live in
the [reference index](references/index.md); [sources.json](references/sources.json) records file hashes.

| Reference | Read for |
| --- | --- |
| [Google Shell Style Guide](references/google/shellguide.md) | Bash naming, formatting, quoting, arrays, functions, and errors |
| [Git CodingGuidelines](references/git/CodingGuidelines) | The shell section: practical POSIX and utility portability |
| [bash-completion style guide](references/bash-completion/styleguide.md) | Bash quoting contexts, arithmetic, and older-version pitfalls |
| [ChromiumOS shell guidelines](references/chromiumos/shell.md) | Dialect selection, `printf`, defaults, and option parsing; heed index caveats |
| [ShellCheck manual](references/shellcheck/shellcheck.1.md) | Dialect selection, source resolution, diagnostics, and directives |
| [shfmt manual](references/shfmt/shfmt.1.scd) | Formatter dialect, layout options, and check mode |

UNSW, Wooledge, and GNU Bash links remain in the index; missing redistribution
permission is not permission to copy an entire guide.
