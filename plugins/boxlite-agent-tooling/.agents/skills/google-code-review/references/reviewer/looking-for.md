# What to look for in a code review

## TL;DR

Review design, behavior, tests, clarity, and surrounding contracts across every assigned line, using [the review standard](standard.md).

## Design

- Check whether the pieces interact sensibly and integrate with the system.
- Decide whether the change belongs here or in a library, and whether the functionality is needed now.

## Functionality

- Check intended behavior and its value to both end users and future developers.
- Inspect edge cases, concurrency, and defects visible from source even when the author has tested the change.
- For user-facing changes such as UI work, try the behavior or request a demo when useful.
- Reason carefully about parallel execution: running the code alone rarely establishes freedom from races or deadlocks.
- Prefer concurrency models whose safety can be understood without unnecessary complexity.

Example: a UI demo can reveal an awkward interaction that is difficult to detect from the diff.

## Complexity

- Check complexity at the line, function, class, and system levels.
- Treat code as too complex when readers cannot understand it quickly or callers and maintainers are likely to introduce bugs.
- Reject speculative generalization and unused functionality; solve the current problem and revisit future needs when they become concrete.

## Tests

- Require suitable unit, integration, or end-to-end tests with the production change, except under the upstream [emergency process](https://github.com/google/eng-practices/blob/3bb3ec25b3b0199f4940b1aa75f0ac5c5753301c/review/emergencies.md).
- Review tests for validity, useful assertions, sensible separation, and maintainability.
- Ask whether they fail when behavior breaks and whether later implementation changes could produce false results.
- Keep test code understandable; being outside the main binary does not justify unnecessary complexity.

## Naming

Choose names long enough to explain purpose and behavior without becoming hard to read.

## Comments

- Require clear, necessary comments that usually explain intent or reasoning.
- Simplify unclear code before adding commentary that narrates it.
- Explain mechanisms when syntax alone is insufficient, such as complex algorithms or regular expressions.
- Recheck existing comments and TODOs for contradictions or obsolete work.
- API documentation should state purpose, usage, and observable behavior.

## Style

- Follow the applicable [style guide](http://google.github.io/styleguide/).
- Label preferences outside the guide `Nit:`; do not block on personal taste.
- Separate major formatting changes from functional work so review, merge, and rollback remain clear.

## Consistency

| Situation | Decision |
| --- | --- |
| Existing code conflicts with a required style rule | Follow the rule, per [the review principles](standard.md#principles). |
| A style recommendation conflicts with surrounding code | Prefer the recommendation unless local inconsistency would confuse readers. |
| No stronger rule applies | Maintain existing conventions. |

File an issue and optionally add a TODO for existing inconsistencies needing later cleanup.

## Documentation

- Update associated READMEs, build/test/release instructions, and generated reference docs when usage changes.
- Reconsider related docs when code is removed or deprecated.
- Request missing documentation.

## Every Line {#every-line}

- Understand every assigned line of human-written code; do not assume a class or function is correct after skimming it.
- Data files, generated code, and large data structures may permit lighter inspection when appropriate.
- Request clarification when code is too hard to understand; clearer code also helps future readers.
- Ensure qualified review for specialized privacy, security, concurrency, accessibility, or internationalization concerns.

### Exceptions {#every-line-exceptions}

- When assigned selected files or concerns, explicitly record the reviewed scope.
- Consider [approval with comments](speed.md#lgtm-with-comments) under the applicable process.
- If approval depends on other reviewers covering the remaining scope, state that explicitly and [respond promptly](speed.md#responses).

## Context

- Read surrounding files and system interactions when the diff alone is insufficient.
- Assess accumulated complexity and test coverage; reject changes that degrade overall code health.

Example: four added lines may make sense locally while revealing that their enclosing 50-line method needs decomposition.

## Good Things {#good-things}

Recognize useful improvements and well-addressed feedback; explain what works so the author can repeat it.

## Summary

| Area | Check |
| --- | --- |
| Design and behavior | Useful functionality, sensible UI, safe concurrency, and current requirements. |
| Verification | Appropriate, valid, maintainable tests. |
| Clarity | Clear names, useful comments, consistent style, and current documentation. |
| Coverage | Every assigned line, relevant context, and overall code health. |

Next: [Navigating a CL in Review](navigate.md)
