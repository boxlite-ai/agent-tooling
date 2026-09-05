from __future__ import annotations

import re
from typing import Any

from .models import ValidationContext

ID_RE = re.compile(r"^[a-z][a-z0-9_]*$")
ROOT_TOPIC = "overview"
MAX_DEPTH = 3
TOPIC_KEYS = {"id", "question", "parent"}


def declared_topics(manifest: Any) -> list[dict[str, Any]]:
    """Topic entries as declared, or [] when the manifest draws a single diagram."""
    if not isinstance(manifest, dict):
        return []
    topics = manifest.get("topics")
    return topics if isinstance(topics, list) else []


def topic_ids(manifest: Any) -> list[str]:
    """Topic IDs in declaration order; ['overview'] for a single-diagram manifest."""
    topics = declared_topics(manifest)
    if not topics:
        return [ROOT_TOPIC]
    return [topic["id"] for topic in topics if isinstance(topic, dict) and isinstance(topic.get("id"), str)]


def parent_of(manifest: Any) -> dict[str, str | None]:
    parents: dict[str, str | None] = {}
    for topic in declared_topics(manifest):
        if isinstance(topic, dict) and isinstance(topic.get("id"), str):
            parent = topic.get("parent")
            parents[topic["id"]] = parent if isinstance(parent, str) else None
    return parents


def validate_topics(ctx: ValidationContext) -> None:
    """Check the topic tree and every item's topic membership.

    Runs once against the whole manifest; the per-topic passes then see a manifest
    filtered to one topic and need no topic awareness at all.
    """
    manifest = ctx.manifest
    topics = declared_topics(manifest)
    if not topics:
        return

    errors: list[str] = []
    ids: list[str] = []
    roots: list[str] = []
    for index, topic in enumerate(topics):
        where = f"topics[{index}]"
        if not isinstance(topic, dict):
            errors.append(f"{where} must be an object")
            continue
        extra = sorted(set(topic) - TOPIC_KEYS)
        if extra:
            errors.append(f"{where} contains unsupported fields {extra}")
        topic_id = topic.get("id")
        if not isinstance(topic_id, str) or not ID_RE.fullmatch(topic_id):
            errors.append(f"{where}.id must be lowercase snake case")
            continue
        if topic_id in ids:
            errors.append(f"{where}.id {topic_id!r} is declared twice")
        ids.append(topic_id)
        if not isinstance(topic.get("question"), str) or not topic.get("question"):
            errors.append(f"{where}.question must be a non-empty sentence")
        parent = topic.get("parent")
        if parent is None:
            roots.append(topic_id)
        elif not isinstance(parent, str):
            errors.append(f"{where}.parent must be a declared topic id")

    if ids and ids[0] != ROOT_TOPIC:
        errors.append(f"topics[0].id must be {ROOT_TOPIC!r}")
    elif roots != [ROOT_TOPIC]:
        errors.append(f"exactly one topic may omit parent, and it must be {ROOT_TOPIC!r}; found {roots}")

    parents = parent_of(manifest)
    for topic_id in ids:
        parent = parents.get(topic_id)
        if parent is not None and parent not in parents:
            errors.append(f"topic {topic_id!r} names undeclared parent {parent!r}")
    # The document opens each topic inside its parent, so its <details> sequence is the
    # tree's pre-order. Requiring the same order here keeps a manifest this validator
    # accepts from being one the document could never satisfy.
    expected = _document_order(ids, parents)
    if expected and ids != expected:
        errors.append(
            f"topics must be declared in document order {expected}; found {ids}"
        )
    _check_depth(parents, errors)
    _check_membership(manifest, ids, errors)

    if errors:
        ctx.add("manifest.topics", "fail", "topic tree is invalid", errors)
    else:
        depth = max((_depth(topic_id, parents) for topic_id in ids), default=1)
        ctx.add(
            "manifest.topics",
            "pass",
            f"{len(ids)} topics form a rooted tree {depth} level(s) deep",
            [f"{topic_id} <- {parents.get(topic_id) or '(root)'}" for topic_id in ids],
        )


def _document_order(ids: list[str], parents: dict[str, str | None]) -> list[str]:
    """Pre-order of the declared tree, children in declaration order.

    Topics inside a parent cycle are unreachable from any root and so are absent from
    the result; the cycle carries its own complaint.
    """
    children: dict[str, list[str]] = {topic_id: [] for topic_id in ids}
    for topic_id in ids:
        parent = parents.get(topic_id)
        if parent in children:
            children[parent].append(topic_id)
    order: list[str] = []
    stack = [topic_id for topic_id in reversed(ids) if parents.get(topic_id) is None]
    while stack:
        topic_id = stack.pop()
        order.append(topic_id)
        stack.extend(reversed(children[topic_id]))
    return order


def _depth(topic_id: str, parents: dict[str, str | None]) -> int:
    depth = 1
    seen = {topic_id}
    current = parents.get(topic_id)
    while current is not None and current in parents and current not in seen:
        seen.add(current)
        depth += 1
        current = parents.get(current)
    return depth


def _check_depth(parents: dict[str, str | None], errors: list[str]) -> None:
    for topic_id in parents:
        seen: set[str] = set()
        current: str | None = topic_id
        cyclic = False
        while current is not None and current in parents:
            if current in seen:
                errors.append(f"topic {topic_id!r} sits in a parent cycle")
                cyclic = True
                break
            seen.add(current)
            current = parents.get(current)
        if cyclic:
            continue
        depth = _depth(topic_id, parents)
        if depth > MAX_DEPTH:
            errors.append(f"topic {topic_id!r} nests {depth} levels deep; the limit is {MAX_DEPTH}")


def _check_membership(manifest: dict[str, Any], ids: list[str], errors: list[str]) -> None:
    known = set(ids)
    for collection in ("nodes", "edges", "boundaries"):
        values = manifest.get(collection, [])
        if not isinstance(values, list):
            continue
        for index, item in enumerate(values):
            if not isinstance(item, dict):
                continue
            where = f"{collection}[{index}]"
            _check_topic_list(item.get("topics"), f"{where}.topics", known, errors)
            owner = set(item.get("topics") or [])
            covered: set[str] = set()
            members = item.get("members") or []
            for member_index, membership in enumerate(members):
                member_where = f"{where}.members[{member_index}].topics"
                _check_topic_list(membership.get("topics"), member_where, known, errors)
                # Without this a member can be projected into no topic at all, and
                # nothing would ever check the target it names.
                outside = sorted(set(membership.get("topics") or []) - owner)
                if outside:
                    errors.append(
                        f"{member_where} names {outside} outside its container's topics"
                    )
                covered |= set(membership.get("topics") or [])
            if members and (uncovered := sorted(owner - covered)):
                errors.append(
                    f"{where} appears in {uncovered} with no member there; "
                    "a container cannot be projected empty"
                )


def _check_topic_list(values: Any, where: str, known: set[str], errors: list[str]) -> None:
    if not values or len(set(values)) != len(values):
        errors.append(f"{where} must be a non-empty unique array of declared topic ids")
        return
    unknown = sorted(value for value in values if value not in known)
    if unknown:
        errors.append(f"{where} names undeclared topics {unknown}")


def filter_manifest(manifest: dict[str, Any], topic: str) -> dict[str, Any]:
    """Project the manifest onto one topic.

    Items outside the topic disappear and every ``topics`` key is dropped, so the
    existing per-topic validators see exactly the manifest shape they already accept.
    Only called for a manifest that declares topics.
    """
    filtered = {key: value for key, value in manifest.items() if key != "topics"}
    for collection in ("nodes", "edges", "boundaries"):
        values = manifest.get(collection)
        if not isinstance(values, list):
            continue
        kept: list[dict[str, Any]] = []
        for item in values:
            if not isinstance(item, dict) or topic not in (item.get("topics") or []):
                continue
            projected = {key: value for key, value in item.items() if key != "topics"}
            members = projected.get("members")
            if isinstance(members, list):
                projected["members"] = [
                    {key: value for key, value in membership.items() if key != "topics"}
                    for membership in members
                    if isinstance(membership, dict) and topic in (membership.get("topics") or [])
                ]
            kept.append(projected)
        filtered[collection] = kept
    kept_ids = _item_ids(filtered)
    declared_ids = _item_ids(manifest)
    filtered["annotations"] = [
        annotation
        for annotation in manifest.get("annotations", []) or []
        if _annotation_belongs(annotation, kept_ids, declared_ids)
    ]
    return filtered


def _item_ids(manifest: dict[str, Any]) -> set[str]:
    return {
        item["id"]
        for collection in ("nodes", "edges")
        for item in manifest.get(collection) or []
        if isinstance(item, dict) and isinstance(item.get("id"), str)
    }


def _annotation_belongs(annotation: Any, kept_ids: set[str], declared_ids: set[str]) -> bool:
    """Keep this topic's annotations, plus any the manifest cannot account for.

    An annotation naming an undeclared target is an error rather than another topic's
    business, so it must reach validate_manifest instead of vanishing in projection.
    """
    if not isinstance(annotation, dict) or not isinstance(annotation.get("target"), str):
        return True
    target = annotation["target"].split(":", 1)[-1]
    return target in kept_ids or target not in declared_ids
