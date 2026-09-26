from __future__ import annotations

import re
from collections import Counter

from .models import ParsedDocument, StateBlock, ValidationContext
from .topics import ROOT_TOPIC, declared_topics, parent_of, topic_ids

VIEW_HEADINGS = {
    "Architecture": "architecture",
    "Sequence": "sequence",
    "Call graph": "call_graph",
}
VIEW_ORDER = ["architecture", "sequence", "call_graph"]
EXPECTED_LANGUAGES = {
    "architecture": "mermaid",
    "sequence": "mermaid",
    "call_graph": "text",
}

H2_RE = re.compile(r"^##\s+(.+?)\s*$")
H3_RE = re.compile(r"^###\s+(.+?)\s*$")
FENCE_RE = re.compile(r"^```([A-Za-z0-9_-]*)\s*$")
DETAILS_OPEN_RE = re.compile(r"^\s*<details>\s*$")
DETAILS_CLOSE_RE = re.compile(r"^\s*</details>\s*$")
SUMMARY_RE = re.compile(r"^\s*<summary><code>([a-z][a-z0-9_]*)</code>\s+—\s+(\S.*?)</summary>\s*$")


def parse_document(ctx: ValidationContext) -> tuple[str, dict[str, dict[tuple[str, str], StateBlock]]]:
    """Parse the document once and return its fenced blocks grouped by topic.

    A manifest without ``topics`` keeps the historical shape: one bare fence per
    view/state, all belonging to the implicit root topic.
    """
    by_topic: dict[str, dict[tuple[str, str], StateBlock]] = {}
    try:
        text = ctx.document_path.read_text(encoding="utf-8")
    except OSError as error:
        ctx.add("document.read", "fail", f"cannot read diagram document: {error}")
        return "", by_topic

    states = ctx.manifest.get("states", [])
    selected_views = ctx.view_ids()
    nested = bool(declared_topics(ctx.manifest))
    topics = topic_ids(ctx.manifest)
    parents = parent_of(ctx.manifest) if nested else {ROOT_TOPIC: None}
    state_by_label = {state.get("label"): state.get("id") for state in states}
    expected = {
        (view, state.get("id"), topic)
        for view in selected_views
        for state in states
        if state.get("id")
        for topic in topics
    }

    lines = text.splitlines()
    current_view: str | None = None
    current_state: str | None = None
    current_label: str | None = None
    view_order: list[str] = []
    view_counts: Counter[str] = Counter()
    fence: tuple[str, int, list[str]] | None = None
    seen: Counter[tuple[str, str, str]] = Counter()
    blocks: dict[tuple[str, str, str], StateBlock] = {}
    state_order_by_view: dict[str, list[str]] = {view: [] for view in VIEW_ORDER}
    topic_stack: list[str] = []
    open_order: dict[tuple[str, str], list[str]] = {}
    awaiting_summary: int | None = None
    errors: list[str] = []

    for line_number, line in enumerate(lines, start=1):
        if fence is not None:
            language, start_line, content = fence
            if line.rstrip() == "```":
                topic = topic_stack[-1] if topic_stack else (None if nested else ROOT_TOPIC)
                if current_view is None or current_state is None or current_label is None:
                    errors.append(f"line {start_line}: fenced block is outside a view/state section")
                elif topic is None:
                    errors.append(f"line {start_line}: fenced block is outside a <details> topic section")
                else:
                    key = (current_view, current_state, topic)
                    seen[key] += 1
                    if key not in blocks:
                        blocks[key] = StateBlock(
                            view=current_view,
                            state=current_state,
                            label=current_label,
                            language=language,
                            content="\n".join(content).strip("\n") + "\n",
                            start_line=start_line,
                            topic=topic,
                        )
                fence = None
            else:
                content.append(line)
            continue

        if awaiting_summary is not None:
            summary_match = SUMMARY_RE.match(line)
            if summary_match is None:
                errors.append(
                    f"line {awaiting_summary}: <details> must be followed by "
                    "'<summary><code>topic_id</code> — question</summary>'"
                )
                awaiting_summary = None
            else:
                awaiting_summary = None
                topic = summary_match.group(1)
                _open_topic(
                    topic,
                    line_number,
                    topic_stack,
                    parents,
                    topics,
                    current_view,
                    current_state,
                    open_order,
                    errors,
                )
                if line_number < len(lines) and lines[line_number].strip():
                    errors.append(
                        f"line {line_number}: leave a blank line after <summary> so the "
                        "fenced diagram renders inside the collapsed block"
                    )
                continue

        fence_match = FENCE_RE.match(line)
        if fence_match:
            fence = (fence_match.group(1), line_number, [])
            continue

        if nested and DETAILS_OPEN_RE.match(line):
            awaiting_summary = line_number
            continue

        if nested and DETAILS_CLOSE_RE.match(line):
            if not topic_stack:
                errors.append(f"line {line_number}: </details> without an open topic section")
            else:
                topic_stack.pop()
            if line_number >= 2 and lines[line_number - 2].strip():
                errors.append(
                    f"line {line_number}: leave a blank line before </details> so the "
                    "fenced diagram renders inside the collapsed block"
                )
            continue

        h2_match = H2_RE.match(line)
        if h2_match:
            heading = h2_match.group(1)
            if topic_stack:
                errors.append(f"line {line_number}: heading {heading!r} sits inside an open topic section")
                topic_stack.clear()
            if heading not in VIEW_HEADINGS:
                errors.append(f"line {line_number}: unexpected level-two heading {heading!r}")
                current_view = current_state = current_label = None
                continue
            current_view = VIEW_HEADINGS[heading]
            if current_view not in selected_views:
                errors.append(f"line {line_number}: view {current_view!r} is not selected by the manifest")
                current_view = current_state = current_label = None
                continue
            current_state = current_label = None
            view_counts[current_view] += 1
            view_order.append(current_view)
            continue

        h3_match = H3_RE.match(line)
        if h3_match and current_view is not None:
            if topic_stack:
                errors.append(f"line {line_number}: state heading sits inside an open topic section")
                topic_stack.clear()
            label = h3_match.group(1)
            state_id = state_by_label.get(label)
            if state_id is None:
                errors.append(f"line {line_number}: unknown state heading {label!r}")
                current_state = current_label = None
            else:
                current_state = state_id
                current_label = label
                state_order_by_view[current_view].append(state_id)

    if fence is not None:
        errors.append(f"line {fence[1]}: unterminated fenced block")
    if awaiting_summary is not None:
        errors.append(f"line {awaiting_summary}: <details> must be followed by a <summary> line")
    if topic_stack:
        errors.append(f"unterminated topic section(s) {topic_stack}")

    if view_order != selected_views:
        errors.append(f"view order must be {selected_views}; found {view_order}")
    for view in selected_views:
        if view_counts[view] != 1:
            errors.append(f"view {view!r} must occur exactly once; found {view_counts[view]}")
        expected_state_order = [state.get("id") for state in states if state.get("id")]
        if state_order_by_view[view] != expected_state_order:
            errors.append(
                f"view {view!r} state order must be {expected_state_order}; found {state_order_by_view[view]}"
            )
    if nested:
        for (view, state), order in sorted(open_order.items()):
            if order != topics:
                errors.append(f"{view}/{state} topic order must be {topics}; found {order}")
    def where(key: tuple[str, str, str]) -> str:
        # An author who never declared topics should not see a topic axis.
        return f"{key[0]}/{key[1]}/{key[2]}" if nested else f"{key[0]}/{key[1]}"

    for key in sorted(expected):
        if seen[key] != 1:
            errors.append(
                f"{where(key)} must contain exactly one fenced block; found {seen[key]}"
            )
        block = blocks.get(key)
        if block and block.language != EXPECTED_LANGUAGES[key[0]]:
            errors.append(
                f"{where(key)} must use a {EXPECTED_LANGUAGES[key[0]]!r} fence; "
                f"found {block.language!r}"
            )
    for key in sorted(set(blocks) - expected):
        errors.append(f"unexpected view/state block {where(key)}")

    if errors:
        ctx.add("document.structure", "fail", "diagram document structure is invalid", errors)
    else:
        ctx.add(
            "document.structure",
            "pass",
            "all selected views, states, and topics have exactly one correctly typed block",
            [where(key) for key in sorted(expected)],
        )

    for (view, state, topic), block in blocks.items():
        by_topic.setdefault(topic, {})[(view, state)] = block
    _validate_diagram_kinds(ctx, blocks, nested)
    return text, by_topic


def _open_topic(
    topic: str,
    line_number: int,
    topic_stack: list[str],
    parents: dict[str, str | None],
    topics: list[str],
    current_view: str | None,
    current_state: str | None,
    open_order: dict[tuple[str, str], list[str]],
    errors: list[str],
) -> None:
    if topic not in topics:
        errors.append(f"line {line_number}: topic {topic!r} is not declared by the manifest")
        topic_stack.append(topic)
        return
    expected_parent = parents.get(topic)
    actual_parent = topic_stack[-1] if topic_stack else None
    if expected_parent != actual_parent:
        errors.append(
            f"line {line_number}: topic {topic!r} is nested under {actual_parent!r} "
            f"but the manifest declares parent {expected_parent!r}"
        )
    topic_stack.append(topic)
    if current_view is not None and current_state is not None:
        open_order.setdefault((current_view, current_state), []).append(topic)


def attach_topic(ctx: ValidationContext, text: str, blocks: dict[tuple[str, str], StateBlock]) -> None:
    """Attach one topic's parsed blocks to the context for the downstream validators."""
    ctx.parsed = ParsedDocument(text=text, blocks=dict(blocks))


def _validate_diagram_kinds(
    ctx: ValidationContext, blocks: dict[tuple[str, str, str], StateBlock], nested: bool
) -> None:
    errors: list[str] = []
    for (view, state, topic), block in blocks.items():
        first = next((line.strip() for line in block.content.splitlines() if line.strip()), "")
        where = f"{state}/{topic}" if nested else state
        if view == "architecture" and not re.match(r"^(flowchart|graph)\s+(LR|RL|TB|TD|BT)\b", first):
            errors.append(f"architecture/{where} must begin with a directed flowchart or graph declaration")
        if view == "sequence" and first != "sequenceDiagram":
            errors.append(f"sequence/{where} must begin with 'sequenceDiagram'")
    if errors:
        ctx.add("document.diagram_kinds", "fail", "unsupported Mermaid diagram kind", errors)
    else:
        ctx.add("document.diagram_kinds", "pass", "all selected Mermaid diagram kinds are supported")
