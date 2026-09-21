---
name: boxlite-examples
description: Explain concepts and changes through concrete examples and verified real-world cases.
---

# BoxLite Examples

Explain through one representative example from the user's task, then state the
principle. Works across projects. Skip examples for trivial or code-only answers.

## Stateful walkthroughs

1. **Shapes and roles:** introduce the actors and state objects. Name each object's
   owner, purpose, relevant fields, and units: database rows, account balances,
   memory bytes, queue contents, or other concrete state.
2. **Relationships:** explain how the objects reference or belong to each other before
   describing execution. Show the whole relevant structure before zooming into a
   part, including ownership boundaries and where that part fits. Distinguish
   contents from metadata describing them. Keep identifiers consistent.
3. **State through time:** make the relevant state before and after each action
   clear. Carry unchanged values forward; mark absent records explicitly. Status
   labels alone are insufficient: include meaningful amounts, contents, and links.
4. **Action and output:** show who receives which input, what changes and why, and
   what is returned or emitted. Distinguish external outcomes from local database
   commits. Each resulting state becomes the next step's starting state.

Choose the form that best answers the reader's question. Use UML when it helps:

- **Sequence diagram:** interactions and ordering across T1/T2/T3; add state notes
  where they explain a transition. One diagram can cover several steps.
- **Object or class diagram:** record shapes, roles, and relationships; use object
  snapshots when concrete field values matter.
- **Spatial sketch:** memory, storage, or nested structures; show ranges, contents,
  and mappings together. ASCII is sufficient when it conveys the layout clearly.
- **Table, calculation, or short prose:** comparing values or explaining a simple
  change. Combine forms only when each adds useful information.

Do not require a diagram per step or repeat unchanged structures. Prefer concrete
numbers with units; T1/T2/T3 indicate order, not duration. Show concurrent overlaps
rather than inventing an order. Add elapsed time only when relevant and known.

Inspect and cite sources for actual behavior. Label illustrative values and
assumptions; never invent measurements or external balances. Preserve accuracy
when simplifying. If an analogy helps, explain its mapping and limits.

Keep comparisons on the same input and snapshots focused on relevant fields.
Adapt detail to the question; simpler explanations need only the useful parts.

Read the worked example relevant to the question:

- [Commerce top-up](references/top-up-example.md): linked database records and
  payment interactions over time.
- [VMM memory](references/vmm-memory-example.md): a whole-memory ASCII layout,
  mapping records, and one byte traced through guest and host addresses.

Their choice of visuals is illustrative, not a required template.
