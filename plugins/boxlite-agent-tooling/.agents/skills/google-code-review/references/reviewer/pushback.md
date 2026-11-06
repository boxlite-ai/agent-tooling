# Handling pushback in code reviews

## TL;DR

Reconsider technical objections, explain justified requirements, and resolve disagreement without sacrificing code health.

## Who is right? {#who_is_right}

1. Consider whether the developer's closer knowledge supports their objection.
2. Accept a sound argument and drop the disputed suggestion.
3. Otherwise, explain the developer's concern and the evidence supporting the requested change.
4. Continue advocating when the code-health benefit justifies the work; remain [polite](comments.md#courtesy).

Small improvements matter; acknowledge the argument even when you disagree.

## Upsetting Developers {#upsetting_developers}

- Do not abandon a justified improvement merely because disagreement might be uncomfortable.
- Pay attention to [how feedback is written](comments.md#courtesy); respectful wording helps separate the technical issue from personal conflict.

## Cleaning It Up Later {#later}

- Resolve complexity introduced by this change before submission, except under the upstream [emergency process](https://github.com/google/eng-practices/blob/3bb3ec25b3b0199f4940b1aa75f0ac5c5753301c/review/emergencies.md).
- Promised follow-up cleanup is easily displaced by other work.
- For existing surrounding problems that cannot be addressed now, file and assign a cleanup issue; optionally link it from a TODO.

## General Complaints About Strictness {#strictness}

- Improve [response speed](speed.md) while retaining justified quality requirements.
- Teams may need time to see the value of stricter review.

## Resolving Conflicts {#conflicts}

Use [The Standard of Code Review](standard.md) to resolve disagreements through evidence, discussion, and escalation when necessary.
