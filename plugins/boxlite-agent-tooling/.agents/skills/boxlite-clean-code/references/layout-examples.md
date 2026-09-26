## TL;DR
Formatting should reveal related concepts and control flow without changing behavior or creating arbitrary style gates.

## How it works
Use the smallest layout change that reduces reading effort. These original sketches use ordinary Python or Java syntax; surrounding application types are illustrative. Checks below describe what to verify, not executed tests.

## F01 — Measure size before prescribing limits

A file-length or line-width distribution can identify outliers worth reading. It cannot establish whether a module has the wrong responsibility.

```python
lengths = [len(text.splitlines()) for text in source_files]
widths = [len(line) for text in source_files for line in text.splitlines()]
report_distribution("file lines", lengths)
report_distribution("line width", widths)
```

Before, a personal threshold labels code bad; after, measurements direct a focused inspection. Look for mixed responsibilities or unreadable expressions before splitting anything. Generated tables and data declarations can be long for good reasons.

**Check:** samples represent the relevant source language and exclude generated files where appropriate; no correctness check fails solely because a number exceeds a preference.

## F02 — Separate concepts, keep related declarations together

A markup renderer benefits from a blank line between initialization and rendering. A configuration object's obvious field comments can instead interrupt a single thought.

```python
class BoldText:
    def __init__(self, content):
        self.content = content

    def render(self):
        return "<b>" + self.content + "</b>"


class ReporterSettings:
    def __init__(self, listener_name, properties):
        self.listener_name = listener_name
        self.properties = properties
```

Before, everything is compressed or each self-explanatory field has a repeated comment; after, spacing marks conceptual boundaries. Preserve comments explaining escaping, protocols, or constraints. The markup sketch assumes already-safe content; reformatting does not establish HTML safety.

**Check:** token-level behavior is unchanged; meaningful comments and escaping behavior survive.

## F03 — Make state easy to locate

Keep a loop variable within the loop and a local resource near its use. Put shared fields in the location expected by the language and repository.

```java
final class TestGroup {
    private final List<TestCase> cases;

    TestGroup(List<TestCase> cases) {
        this.cases = cases;
    }

    int countCases() {
        int count = 0;
        for (TestCase test : cases) {
            count += test.countCases();
        }
        return count;
    }
}
```

This replaces declarations distant from their use or buried between unrelated methods. The same principle applies to a preference-file stream and a runner created for one test suite. Moving a variable must preserve initialization order, lifetime, and cleanup; moving locals into fields does the opposite.

**Check:** loop state cannot leak into the next operation; shared state remains visible to readers. Use the language's resource construct when cleanup is part of the change rather than copying incidental historical error handling.

## F04 — Let readers follow an operation into its details

A page responder should reveal the request path before its parsing and rendering helpers.

```python
def respond(request, pages):
    name = requested_name(request, default="Home")
    page = pages.find(name)
    return not_found(name) if page is None else render_page(page)


def requested_name(request, default):
    return request.resource if request.resource.strip() else default
```

Before, parsing and low-level details appear in an arbitrary order; after, the entry point leads naturally to its collaborators. A code analyzer can similarly group file discovery, file measurement, and metric queries, keeping each helper near the operation it supports.

**Check:** blank/default behavior and lookup/render order remain the same. Respect language declaration requirements and meaningful module boundaries; proximity is not a reason to create a giant file.

## F05 — Keep the default with the policy owner

```python
# Before: the generic selector secretly chooses the application's landing page.
name = choose_name(request.resource)

# After: the request handler owns that choice.
name = choose_name(request.resource, default="Home")
```

The helper decides whether a supplied name is usable; the caller decides which landing page the application wants. This does not justify injecting every constant. A conversion factor intrinsic to a calculation belongs with that calculation.

**Check:** blank, whitespace-only, and explicit names produce exactly the intended results; all existing callers receive an explicit compatible default.

## F06 — Group conceptual siblings

```python
def expect_enabled(value, message="expected enabled"):
    if not value:
        raise AssertionError(message)


def expect_disabled(value, message="expected disabled"):
    if value:
        raise AssertionError(message)
```

Related assertion variants belong together even when they do not call each other. The same holds for overloads or operations sharing a domain vocabulary. Do not merge distinct behavior merely because names look alike.

**Check:** default and supplied messages remain correct for both truth values; reordering changes no registration or initialization effects.

## F07 — Use whitespace and grouping to expose expressions

```python
line_width = len(line)
total_characters += line_width
record_width(line_width, line_number)

root = (-b + math.sqrt(b * b - 4 * a * c)) / (2 * a)
```

Assignments, separate arguments, and arithmetic groups should be easy to recognize. Follow the formatter rather than maintaining fragile manual spacing that it will erase. Parentheses make grouping explicit without depending on a reader's interpretation of whitespace.

**Check:** formatting preserves evaluation order and operand types. Do not silently replace a numeric algorithm or change its domain while improving layout.

## F08 — Alignment does not repair excessive state

```python
self.socket = socket
self.request_deadline_ms = request_deadline_ms
self.bytes_received = 0
```

Before, columns of names and values require manual realignment; after, normal assignment formatting exposes each relationship. If a network handler has unrelated timing, rendering, storage, and session fields, investigate its responsibilities rather than aligning a longer list.

**Check:** the formatter remains stable on a second run. A long field name or several related fields alone does not justify extracting another class.

## F09 — Make scopes visible

```python
def serve(connection, timeout_ms):
    try:
        sender = ResponseSender(connection, timeout_ms)
        sender.start()
    except ResponseFailure as error:
        record_failure(error)
```

Flattened code makes the protected operation and error boundary hard to see. Indentation reveals them. Short constructors or render methods also benefit from consistent local conventions; expression-bodied methods can be idiomatic in some languages.

**Check:** exception scope, return placement, and effects match the original. In indentation-sensitive languages, formatting can change behavior and deserves a semantic diff review.

## F10 — Show intentional empty loop bodies

```java
while (input.read(buffer) != -1) {
    // Drain the stream; this protocol intentionally discards these bytes.
}
```

A semicolon at the end of a loop can look accidental. An explicit empty body shows that reading itself performs the work. The rationale comment matters because it explains deliberate data discard.

**Check:** every read still occurs, EOF terminates, errors propagate as intended, and the read contract cannot cause an unintended busy loop. Do not replace draining with a no-op.

## F11 — Let the team convention be the reusable example

```text
Apply the repository formatter to the touched code.
Run it again: the second run should produce no change.
Review the semantic diff separately from the layout.
```

A representative analyzer module can demonstrate declaration placement, related helper grouping, and consistent spacing more clearly than many personal rules. Use the team's chosen formatter instead of imposing the example author's preferences.

**Check:** avoid unrelated repository-wide churn; formatting examples do not validate an analyzer's resource cleanup, statistics, or error handling.
