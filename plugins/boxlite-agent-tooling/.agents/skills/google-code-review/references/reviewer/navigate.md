# Navigating a CL in review

## TL;DR

Check the change's purpose, inspect its main design, then review every assigned file in a logical order.

## Summary

1. Read the [description](https://github.com/google/eng-practices/blob/3bb3ec25b3b0199f4940b1aa75f0ac5c5753301c/review/developer/cl-descriptions.md) and decide whether the change belongs.
2. Inspect the main changes for overall design problems.
3. Review the remaining scope using [the coverage guide](looking-for.md).

## Step One: Take a broad view of the change {#step_one}

- Read the description alongside the change.
- If its direction is wrong, explain promptly and courteously; suggest a useful alternative.
- Repeated unwanted changes indicate a need for earlier team or contributor communication.

Example: “FooWidget is being retired; please apply this improvement to BarWidget instead.”

## Step Two: Examine the main parts of the CL {#step_two}

- Start with the files containing the main logical changes; they provide context for smaller changes.
- If the main parts are unclear, ask where to start or request [smaller changes](https://github.com/google/eng-practices/blob/3bb3ec25b3b0199f4940b1aa75f0ac5c5753301c/review/developer/small-cls.md).
- Send major design feedback promptly, even before the remaining review is ready.

Early feedback prevents dependent work from building on a flawed design and gives the author time for substantial rework.

## Step Three: Look through the rest of the CL in an appropriate sequence {#step_three}

- Choose a logical file order and track coverage so no assigned file is missed.
- After the main files, the review tool's order often suffices.
- Read tests first when they clarify intended behavior.

Next: [Speed of Code Reviews](speed.md)
