## TL;DR

A parser refactor succeeds when it localizes a real new option type while preserving defaults, consumption, and diagnostics across small working steps.

## How it works

These compact examples adapt the Args case into transformation steps and schematic Python fragments. They describe contracts to verify, not a replacement parser implementation.

### A01 — Give callers one coherent parsing operation

Before, application code inspects tokens, interprets types, records errors, and decides whether partially parsed state is safe. After, a parser returns a usable result or a structured failure:

```python
parsed = parse_options(schema, command_line)
start_service(port=parsed.integer("port"), logging=parsed.flag("log"))
```

The public operation owns schema validation and argument interpretation. Callers do not assemble a required sequence of parser internals.

**Check:** invalid schema, unknown option, missing value, and invalid number must not expose a misleading successful result. Record whether getters supply defaults and whether callers can ask for the wrong type.

**Limit:** successful construction is one possible language idiom; a result value is another. Stopping at the first positional token and skipping positional tokens are different contracts. A final redesign must not silently introduce the former while calling the change a refactor.

### A02 — Stop when a real addition multiplies change

A Boolean-only parser needs one value store. Adding text and integer options creates matching branches in schema parsing, token conversion, and result retrieval.

```text
Before adding the next type:
schema branch → choose per-type map
token branch  → convert into that map
getter branch → select that map

Proposed boundary:
schema selects a value reader → reader consumes/stores its value
```

The reason for a reader abstraction is the same distinction repeatedly driving changes. Check the next already-required type against this design before committing to it.

**Check:** enumerate the places an actual new type must change and the knowledge each place needs. Schema recognition and public typed access may still need deliberate changes; success does not mean zero edits everywhere.

**Limit:** a small fixed parser may remain clearer with direct branches. Similar-looking conversion code does not alone justify a registry, inheritance tree, or plugin framework.

### A03 — Move null protection with the representation

Wrapping a formerly optional value adds a new dereference:

```python
# Before: a missing value directly produces the existing default.
return flags.get(name, False)

# Broken migration: the reader itself can be absent.
return readers.get(name).value

# Preserve the established absent-option behavior.
reader = readers.get(name)
return False if reader is None else reader.value
```

The old defaulting logic guarded a value. It no longer guards the wrapper introduced by the refactor.

**Check:** query an option absent from the schema as well as one declared but absent from the command line. Run the check immediately after moving the representation.

**Limit:** this example preserves a known fallback; it does not recommend swallowing invalid queries in every API. Wrong-type lookup is a separate contract.

### A04 — Use temporary scaffolding, then remove it

Keep the system runnable through this sequence:

1. Add an unused reader skeleton.
2. Route one existing type through it; retain the old public getter.
3. Move that type's state and conversion into its reader.
4. Repeat for the next type, checking behavior between moves.
5. Reduce the common contract to what readers actually share.
6. Delete obsolete fields, overloads, forwarding functions, and temporary casts.

The intermediate parent may temporarily hold state that belongs in children. It is a migration stage, not evidence that the final parent should know every concrete value type.

**Check:** each move preserves missing/invalid values and consumption. Stop and restore the relevant tests when a move fails; do not stack unrelated refactors on a failing state.

**Limit:** use the language's simplest suitable dispatch mechanism. A function table or tagged value can provide the same boundary without a class hierarchy.

### A05 — Merge stores without losing acceptance behavior

Introduce the common store alongside existing stores. Populate both with the same reader object, move consumers one at a time, and remove each old store only after its last consumer moves.

An easy-to-miss acceptance contract is a wrong-type lookup:

```python
# Existing contract for this example only:
assert parse_options("count:integer", ["--count", "4"]).flag("count") is False
```

A unified store may now retrieve an integer reader where the old Boolean-only store returned “absent.” Component tests can stay green while callers observe a cast error or truthy integer.

**Check:** run the public acceptance scenario, not just each reader's happy-path tests. Check absent, declared-but-unset, and wrong-type lookups independently. Include the relevant acceptance checks in the routine validation entry point.

**Limit:** preserve this behavior only where it is established. Do not spread exception-catching defaults into unrelated APIs.

### A06 — Move token consumption with conversion

Before, each setter reaches into a shared argument array and advances a separate cursor. After, each value reader receives the token stream it consumes:

```python
reader = readers.get(option_name)
if reader is None:
    raise UnknownOption(option_name)
reader.consume(tokens)
```

Migrate the dispatch branches individually. Once each branch invokes the same operation, remove the duplicated type checks. Moving the unknown-option guard first prevents its behavior from disappearing with the final branch.

**Check:** a flag consumes no following value; an integer consumes exactly one; missing input identifies the current option; malformed input retains the offending token. Confirm what happens after the first positional token and after an error.

**Limit:** an iterator expresses a real protocol, not just a shorter argument list. Hiding the cursor in unrelated global state would reduce parameter count while making ownership worse.

### A07 — Exercise the boundary with a real new type

For a required decimal option, add cases in this order:

| Input | Required observation |
| --- | --- |
| `--ratio 1.25` | The decimal value is available through the intended API. |
| `--ratio many` | The failure identifies invalid numeric input and preserves the token. |
| `--ratio` | The failure distinguishes missing input from invalid input. |

The implementation change should largely live with decimal consumption and conversion, plus deliberate schema/public-API/error-category additions. This is practical evidence that the boundary helps.

**Check:** the new tests must call the parser and its real readers. An assertion about a decimal value created entirely in the test does not evaluate the boundary.

**Limit:** do not add speculative argument types solely to justify the abstraction. Keep established precision, accepted spellings, and numeric range behavior explicit.

### A08 — Move error ownership without erasing information

A conversion layer knows the invalid token; the parser knows which option selected that converter; presentation knows how to describe the failure.

```text
converter: InvalidNumber(token)
parser:    attach option identity, preserve cause
presenter: render the application's diagnostic
```

Move validity flags and error metadata out of unrelated parser state in small steps. A domain exception may carry canned messages for convenience, but callers should still be able to inspect structured failure information.

**Check:** missing versus invalid values, option identity, original parameter, cause, and first-error behavior. A CLI additionally checks diagnostic stream, text, and exit status where those are its contract.

**Limit:** replacing a status-returning API with exceptions, changing error wording, or replacing accumulated errors with fail-fast behavior changes compatibility. Plan those changes explicitly; they are not consequences to hide inside structural cleanup.
