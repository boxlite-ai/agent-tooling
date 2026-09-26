## TL;DR

Build entry points, type choices, and diagnostic tests should expose real contracts instead of hiding dependencies or suppressing failures.

## How it works

These original adaptations distinguish durable design lessons from historical language preferences. Checks describe useful validation; no execution of these examples is claimed.

### H02 — Make build and test entry points discoverable

Before, a developer must remember checkout order, manual dependency copying, and several context-sensitive build commands. After, a fresh checkout provides documented operations:

```text
project build
project test
```

These names are illustrative. The repository can use its existing package manager, build system, or script; the goal is a reliable entry point that owns the required sequence.

**Check:** run from the documented directory in a clean environment, confirm required dependencies are declared, and verify a failing compiler or test makes the command fail. Preserve meaningful stderr and exit status.

**Limit:** installation, credentials, and optional integration setup may remain separate. A convenient wrapper that silently skips unavailable tests or masks failures does not satisfy the goal.

### H23 — Import syntax is not architectural independence

A historical recommendation replaces a long list of Java class imports with a package wildcard. Treat that as a style preference to evaluate, not a universal dependency reduction:

```text
explicit imports: reveal each referenced symbol
wildcard import:  changes how unqualified names are resolved
either form:     code still depends on the symbols it uses
```

Use the repository's language tooling to organize imports. Resolve name collisions clearly and keep actual package boundaries meaningful.

**Check:** compilation, ambiguity resolution, and dependency declarations stay correct after import cleanup.

**Limit:** wildcard behavior differs by language. Do not carry this preference into languages where importing a package changes execution, public exports, or namespace behavior in a materially different way.

### H24 — Do not inherit a type solely to reach its constants

Before, a payroll class gains access to rate constants through a superclass that implements a constants-only interface. The inheritance chain hides the owner and invents a type relationship.

```text
Employee → PayrollConstants interface → unqualified threshold
                  ↓
Employee uses PayrollPolicy.threshold explicitly
```

An explicit import or qualified reference communicates ownership without making employees instances of a constants container.

**Check:** values and arithmetic stay unchanged; no consumer relies on the removed public supertype or reflected interface membership.

**Limit:** public inheritance removal can break compatibility despite unchanged local calculations. A stable domain type may legitimately expose constants that belong to its own contract.

### H25 — Give pay-grade values a domain type

Before, an unexplained integer selects a grade and callers repeat its rate mapping. After, a meaningful value or policy owns the mapping:

```text
grade code → validate → Grade.APPRENTICE
compensation calculation → grade's applicable rate
```

An enum can hold stable grade-specific behavior; a data record can pair a grade with an externally configured rate. Both communicate more than an interchangeable integer.

When every variant must provide behavior, a required operation or an exhaustive match can make omissions visible instead of relying on each caller to remember a convention.

**Check:** external code conversion, every supported grade, unknown codes, and rate/rounding behavior.

**Limit:** rates that vary by date, location, or contract may belong in effective-dated configuration. Do not hardcode changing business policy into an enum merely because the language permits enum methods.

### H31 — Arrange failures to reveal the boundary

A test report shows all values longer than five characters failing. Instead of adding an isolated example, compare the neighborhood:

| Input family | Diagnostic purpose |
| --- | --- |
| Length 4, 5, 6 | Locate an off-by-one threshold. |
| Same length, different contents | Distinguish size from character-sensitive behavior. |
| Negative, zero, positive second argument | Find a sign-dependent branch. |
| Failing inputs and branch coverage | Identify paths that never execute or always execute. |

The pattern suggests where to investigate. Trace the production calculation and explain the invariant before selecting a fix.

**Check:** the test fails at the actual defect, passes with the fix, and retains representative neighboring cases. Expected values should come from the domain contract, not the implementation formula copied into the test.

**Limit:** correlated failures do not prove cause. Do not encode an arbitrary “length five” restriction simply because that was the observed threshold.

### H32 — Investigate a failed safeguard instead of disabling it

Before, a build is made green by disabling a warning or ignoring a failing test. After, determine what the safeguard is telling you:

```text
warning → locate unsafe assumption or document a narrowly justified exception
test failure → reproduce defect or establish an intentional contract change
serialized identity → verify the declared compatibility policy
```

An explicit manual compatibility mechanism can be appropriate; it needs evidence about the state it permits, not an automatic “never override” rule.

**Check:** the original failure is understood, the real defect or contract mismatch is addressed, and broad checks remain enabled. A deliberate suppression is narrow, documented, and independently validated.

**Limit:** a failing test can itself be wrong, but changing it requires a grounded expected contract. “The build passes now” is not evidence when the relevant observation was removed.
