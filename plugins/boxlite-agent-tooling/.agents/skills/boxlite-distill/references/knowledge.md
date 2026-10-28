## TL;DR

Preserve the ideas and relationships needed to answer one learning question, with an example that makes the reasoning visible.

## Details

### Extract

1. Read the relevant material before selecting. Identify its main claim, supporting mechanism, prerequisites, and limits.
2. Separate essential ideas from repetition and context that does not change the answer. Selection spans the topic; every sentence need not survive.
3. Order retained ideas by dependency. Define only terms the intended reader needs; explain why each idea enables the next.
4. Paraphrase faithfully. Preserve exceptions, uncertainty, conditions, quantities, units, and the distinction between correlation and causation.

### Demonstrate

Carry one concrete example through the reasoning. Include a boundary or counterexample when it explains a necessary condition. Label illustrative values; keep source claims traceable.

Illustrative source: "Only retry failed requests that are idempotent. Allow at most three total attempts, stopping immediately after success. The dashboard displays attempts in blue."

| Retain | Why |
| --- | --- |
| Failed **and** idempotent | Determines whether retrying is allowed |
| Three total attempts | Bounds repetition, including the first attempt |
| Stop on success | Prevents an unnecessary repeat |

Example: an idempotent request fails once, succeeds next, and stops after two attempts. A non-idempotent failure is not retried under this rule. Dashboard color is omitted because it does not affect the retry decision.

### Check

- Read the extraction alone: are the topic, references, and logical connections clear?
- Compare it with the source: did a qualified claim become absolute, a prerequisite vanish, or a causal arrow reverse?
- Can the reader apply the idea to the example and explain where it stops applying?
- For conflicting or incomplete evidence, retain the uncertainty and name the missing check.
