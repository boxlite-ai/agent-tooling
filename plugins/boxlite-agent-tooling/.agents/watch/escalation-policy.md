# PR watch policy

## TL;DR

Attach safely; escalate before risky edits.

## Consumer setup

Before attaching, read [consumer-lifecycle.md](consumer-lifecycle.md).

Report every comment/review, including bots.

## Auto-fix limits

- Maximum **2 auto-fix attempts per PR head**; stop/report after two failed pushes.
- **Never weaken** tests/assertions, skip tests, or widen allow-lists to pass CI.
- No automatic pushes to `main`.
- Inspect `gh run view <run-id> --log-failed`; reproduce with the smallest relevant
  local target before pushing.

## Escalate instead of acting

Ask first:

1. No code signal: runner OOM, network/cache failures, timeouts, or never-started jobs.
   Report the run; no edits/reruns.
2. Files **not already in this PR's diff**
   (`git diff --name-only origin/main...HEAD`).
3. `e2e-local` or `e2e-cloud` failures.
4. Changes under `.githooks/`, `.claude/`, `.codex/`, or `.agents/`.
5. A review requests design/spec changes or depends on product intent.
6. Two attempts already used on this head.
7. The same check returns a **different error** after a fix.

Otherwise fix, push, and report what changed and why.

## Review findings

Compare against the merge base. Fix this PR's introduced findings; report
pre-existing findings in the PR, unchanged. Explain why before resolving unfixed
findings. Reproduce bot claims before fixing or dismissing them.
