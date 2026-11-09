## TL;DR

These scripts implement host lifecycle checks and audit runners; the manifests select when each hook runs.

## Entry points

- [Architecture](../../ARCHITECTURE.md#entry-points): each script's caller, input, and contract.
- [Host wiring](../../hooks/README.md): events and host differences.
- [Git hooks](../../.githooks/README.md): commit/push enforcement.
- [Audit](audit/README.md): the verdict gate, audit runners, and the Stop flow.

Host callbacks read JSON on stdin; runners take positional arguments. Each hook's output and exit status follow its host event contract. Shared state and parsing live in [`../lib/`](../lib/); runtime files live under the consumer's ignored `.agents/state/`.

## Layout

- Registered hook entry points stay in this directory; [`audit/`](audit/README.md) holds the audit runners, verdict checker, and schema.
- Scripts resolve grouped helpers and shared libraries from the plugin root.
- Copy the standalone reminder and its Markdown companion together when installing it outside the plugin.

## Tests

Run suites as [Contributing](../../CONTRIBUTING.md#validation) describes.

- Pass `fast` to the [TL;DR suite](../../tests/session/tldr-gates.test.sh) to check denials in under a minute. Its full matrix takes over ten minutes.
- Set `TLDR_GATES_CASES=<label>,…` to run only those cases; a label that runs no case fails the suite.
- [PR question replies](../../tests/scripts/pr-question-reply.test.sh) cover managed answers on both host routes.
- [PR fixtures](../../tests/pr/fixtures/) hold recorded test inputs.
