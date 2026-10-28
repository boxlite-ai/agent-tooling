## TL;DR

Explain the original design through actual component responsibilities, owned state, interfaces, and collaboration; connect that design to the reduced example.

## Details

### Trace the design

- Inventory major responsibilities within the requested boundary before selecting a deep dive. Account for each as explained, grouped with a reason, outside the requested boundary, or unknown. A major area remains part of the overview even when the demo does not use it.
- Inspect declarations, fields, construction, and callers. Use the source's actual classes, structs, traits, modules, or functions; qualify ambiguous names. Do not invent classes for other programming styles.
- Refine important boundaries with representative components. Group incidental helpers; avoid a complete symbol catalog or equal depth for every subsystem.
- Identify what each component owns or borrows, its responsibility, its important contract, and its collaborators. Verify these relationships from code rather than names.
- Explain useful design boundaries and trade-offs. Separate documented rationale from your inference; do not attribute inferred intent to authors.

### Present

- Give a compact responsibility map: **area → actual components → role/state → interfaces/collaborators → source**. Keep the overview at one abstraction level; link deeper internals. A list of subsystem names alone does not establish coverage.
- Use a small diagram when it clarifies relationships. Label edges such as owns, implements, calls, or signals; composition and calls do not imply inheritance.
- Carry one concrete operation through those components in execution order. Show inputs, state changes, boundary crossings, and result, including relevant startup, completion/cleanup, and failure boundaries.
- Keep original roles visible when a teaching example collapses layers. Label example components distinctly; the implementation guide owns the reduction map.

### Check

- Can the reader locate major responsibilities beyond the demo, identify state owners, explain component roles, and follow their connections?
- Do the table, diagram, code, and trace agree on ownership and interactions? Are qualified names and platform/version limits accurate?
- Are unexplained or uninspected areas explicit limits? Do not claim whole-design coverage from a selected subsystem, unsupported names, or an incomplete inventory.
