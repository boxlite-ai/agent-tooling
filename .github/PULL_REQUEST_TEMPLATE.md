## Call graph

```text
Before
  <command or host event the person triggers>
  └─ fn_name (Type · path/file.ext:LOC)  ← BUG: what goes wrong

After
  <command or host event the person triggers>
  └─ fn_name (Type · path/file.ext:LOC)  — new behavior; guarded by <test name>
```

Fixes #<n>
<!-- bug fixes only: keep the Fixes line and the BUG marker; delete both otherwise -->

## Why

<the problem, why this change solves it, and the alternatives rejected>

## User-facing change

NONE

## Verification

<commands run and what they showed; for a fix, the test failing on the reverted change and passing on the restored one>
