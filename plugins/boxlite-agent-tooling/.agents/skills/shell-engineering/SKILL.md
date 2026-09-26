---
name: shell-engineering
description: Engineer Bash hooks and gates while preserving I/O, fail-closed state, and concurrency.
---

# Shell Engineering

Apply the `boxlite-clean-code` skill for general design and test quality.

Treat shell as a small program, not a command transcript. Before restructuring a hook,
preserve its host-facing stdin, stdout, stderr, and exit-code contract.

## Design

- Keep the executable as the composition root: dependency checks, library loading,
  input parsing, then one command/event dispatch.
- Put cohesive reusable behavior in `.agents/lib/`. Sourced libraries have no top-level
  mutation, exit, stdin read, or output.
- Namespace exported functions and module variables; Bash has one global function table.
- Give lifecycle transitions one serialization owner. Do not encode state machines as
  cooperating booleans or make callers assemble lock order.
- Pass cross-module values explicitly. Avoid dynamic dispatch, dynamic function names,
  `eval`, inheritance emulation, and executable text built from data.

## Boundaries and failure

- Reuse `verdict-audit-state.sh` for bounded reads, atomic writes, inode checks, and
  state paths; do not recreate security-sensitive file primitives.
- Use `printf` for machine output, quote expansions unless documented splitting is
  intended, and pass data through arguments or authenticated encoding.
- Preserve explicit failure propagation. Before adding `set -e`, audit every conditional,
  pipeline, command substitution, and expected nonzero branch. Preserve intentional
  `set -uo pipefail` behavior.
- Check required commands at the executable boundary; libraries document assumptions.
- Keep cleanup recoverable and narrow. Never recursively delete runtime state.

## Concurrency review

Draw start, escalation, selection, completion, new-prompt, and teardown as interleaved
timelines. Identify each state-file owner and the lock covering every check/write pair.
Bound locks, reads, waits, receipt counts, and leases. Test regular files, symlinks,
FIFOs, directories, stale/malformed records, replacement generations, and replayed
notifications as distinct inputs.

## Verify

1. Exercise stdin, stdout, stderr, and exit behavior at the public script boundary.
2. Run `bash -n` on every changed shell file.
3. Run `shellcheck -x` when available; annotate every dynamic source with a nearby
   `# shellcheck source=` directive.
4. Run the focused hook suite, host parity, then all plugin `*.test.sh` suites.
5. Run `scripts/sync-guidance.sh --check` and `git diff --check`.

References: [GNU Bash](https://www.gnu.org/software/bash/manual/bash.html),
[ShellCheck](https://github.com/koalaman/shellcheck/blob/master/shellcheck.1.md), and the
[Google Shell Style Guide](https://google.github.io/styleguide/shellguide.html).
