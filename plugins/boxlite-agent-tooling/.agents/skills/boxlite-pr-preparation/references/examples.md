# Examples for PR Review

Show input or starting state → action → result. Explain why the result follows;
link relevant source/tests. Choose the smallest faithful form for the changed behavior.

| PR type | Smallest useful illustration |
| --- | --- |
| Bug fix | Reproducer or focused test showing failure before and success after |
| Feature/API | Working invocation with expected output |
| Refactor | Same input/output, plus the changed internal path or preserved invariant |
| UI | Before/after screenshots and interaction steps |
| Configuration/CI | Concrete configuration or event → resulting behavior |
| Documentation | Before/after wording or corrected usage |

Prefer runnable calls or existing focused tests for behavior changes. Include
prerequisites, invocation/steps, and expected results. Reuse project code/tests
instead of reimplementing the change in a separate demo.

Label illustrative or unrun examples; report actual execution in Verification.
Keep examples current when the diff changes. No fixed code length or new test is
required. Examples explain the change; they do not replace its verification.

Illustrative documentation case: `recieve` → `receive`, with a link to the corrected
section. A runnable code sample would add nothing to that spelling correction.
