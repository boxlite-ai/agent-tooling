# Contributing

- Read [ARCHITECTURE.md](ARCHITECTURE.md) first: entry points, invariants, the Stop gate's decision table, and the vocabulary used below.
- Form follows content: numbered list for a sequence; bullets for 2 to 7 parallel items; description list for name plus description; table when items carry 3 or more attributes or several conditions decide an outcome; prose, message first, for reasoning and trade-offs.

## Commit & PR messages

The preflight hook's denials point here as `CONTRIBUTING.md #commit--pr-messages`; keep this heading so that anchor resolves.

### Commit messages

- Subject: Conventional Commit, no longer than 72 characters.
- Body: the why. The problem, why this change solves it, the alternatives rejected.
- Squash merges keep commit messages and drop the PR body, so a why that lives only in the PR never reaches `git log` or `git blame`.

### Pull request descriptions

| Order | Section | Content | Checked by |
| --- | --- | --- | --- |
| 1 | `## Call graph` | first non-blank content; one column-one `text` fence with the changed end-to-end Before/After graph | preflight hook |
| 2 | `Fixes #<n>` | bug fixes only; first non-blank line after the fence; the faulty Before hop carries `← BUG:` | preflight hook |
| 3 | `## Why` | the problem, why this change solves it, the alternatives rejected | reviewer |
| 4 | `## User-facing change` | one line: what the agent or human now sees differently, or `NONE` | reviewer |
| 5 | `## Verification` | commands run and what they showed; for a fix, the test failing on the reverted change and passing on the restored one | reviewer |

Graph rules:

- Root: the command or host event a person triggers (`git commit`, `gh pr create`, the Stop event).
- Leaves: what they observe (a denial message, a dossier path, a question card). After leaves may name the test that guards each changed hop.
- Every hop carries `(Type · path:LOC)`; every changed hop carries a plain-word annotation.
- Only the hops that change; elide the rest.

Extra views, only when the graph cannot carry the feature:

| Feature is about | Add |
| --- | --- |
| ordering, retries, cancellation, a re-wake | a `sequence` fence after the graph |
| a decision or transition in ARCHITECTURE.md | the changed table row |
| a message or format | one real command and its output |

- `.github/PULL_REQUEST_TEMPLATE.md` carries this shape for PRs opened in the web UI, which the hook never sees.
- Paste bodies into `gh pr create --body '…'` single-quoted: the fence's backticks are command substitution inside double quotes, and the hook denies the command.
- CI commits `UNREVIEWED.md` to a new pull request, converts it to a draft, and reports `Author reviewed the PR` as failing. Read the diff, delete the file in a commit, then mark the pull request ready; a PR merged without that carries the file onto the default branch.

````markdown
## Call graph

```text
Before
  boxlite exec <box> -- <cmd>                                              — user command
  └─ exec_box            (BoxHandle · src/boxlite/src/portal/exec.rs:88)
       └─ open_console   (Jailer · src/boxlite/src/jailer/console.rs:41)  ← BUG: returns before the socket binds
            └─ attach_stdio (Guest · src/guest/src/io.rs:12)              — never reached; the user gets an empty prompt

After
  boxlite exec <box> -- <cmd>                                              — user command
  └─ exec_box            (BoxHandle · src/boxlite/src/portal/exec.rs:88)
       └─ open_console   (Jailer · src/boxlite/src/jailer/console.rs:41)  — awaits the bind future
            └─ attach_stdio (Guest · src/guest/src/io.rs:12)              — guarded by console::binds_before_attach
```

Fixes #1042

## Why

- `open_console` returned as soon as the bind future existed, so `attach_stdio` raced the socket and the first `exec` showed an empty prompt.
- Awaiting the bind is the smallest change that orders the two.
- Rejected: polling the socket path; it races the unlink the jailer performs on restart.

## User-facing change

`boxlite exec` no longer shows an empty prompt on the first attach.

## Verification

- `cargo test -p boxlite console::binds_before_attach`: fails on the reverted change with "attach before bind", passes with it restored.
````
