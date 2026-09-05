from __future__ import annotations

from typing import Any

from .models import ValidationContext

COLLECTIONS = ("nodes", "edges", "boundaries")
VIEWS = ("architecture", "sequence", "call_graph")


def validate_shape(ctx: ValidationContext) -> bool:
    """Type-gate the manifest before any pass that predates ``validate_manifest``.

    ``validate_topics``, ``filter_manifest``, and ``parse_document`` all read the
    manifest before its own validator runs, and each of them indexes, hashes, or
    iterates raw values. Rather than hardening every such site, this gate runs first
    and rejects the ill-typed input as a whole, so those passes can trust what they
    read. It checks only the fields those three passes touch; every other rule stays
    ``validate_manifest``'s job.

    Returns True when the later passes may run.
    """
    manifest = ctx.manifest
    if not isinstance(manifest, dict):
        ctx.add("manifest.types", "fail", "evidence root must be a JSON object")
        return False

    errors: list[str] = []
    _check_states(manifest.get("states"), errors)
    _check_views(manifest.get("views"), errors)
    topics_declared = _check_topics(manifest.get("topics"), errors)
    _check_items(manifest, topics_declared, errors)
    if not isinstance(manifest.get("annotations", []), list):
        errors.append("annotations must be an array")

    if errors:
        ctx.add("manifest.types", "fail", "evidence manifest has ill-typed fields", errors)
        return False
    ctx.add("manifest.types", "pass", "every field the pre-manifest passes read is well typed")
    return True


def _check_views(views: Any, errors: list[str]) -> None:
    if views is None:
        return
    if not isinstance(views, list) or not all(isinstance(view, str) for view in views):
        errors.append("views must be an array of strings")
        return
    # The document pass keys per-view state ordering by these names.
    unknown = sorted(set(views) - set(VIEWS))
    if unknown:
        errors.append(f"views names unknown views {unknown}")


def _check_states(states: Any, errors: list[str]) -> None:
    if not isinstance(states, list) or not states:
        errors.append("states must be a non-empty array")
        return
    for index, state in enumerate(states):
        where = f"states[{index}]"
        if not isinstance(state, dict):
            errors.append(f"{where} must be an object")
            continue
        # Both become dictionary keys while the document is parsed.
        for field in ("id", "label"):
            if not isinstance(state.get(field), str):
                errors.append(f"{where}.{field} must be a string")


def _check_topics(topics: Any, errors: list[str]) -> bool:
    if topics is None:
        return False
    if not isinstance(topics, list):
        errors.append("topics must be an array")
        return False
    if not topics:
        errors.append("topics must declare at least one topic")
        return False
    for index, topic in enumerate(topics):
        where = f"topics[{index}]"
        if not isinstance(topic, dict):
            errors.append(f"{where} must be an object")
            continue
        if not isinstance(topic.get("id"), str):
            errors.append(f"{where}.id must be a string")
        if not isinstance(topic.get("question"), str):
            errors.append(f"{where}.question must be a string")
        if "parent" in topic and not isinstance(topic["parent"], str):
            errors.append(f"{where}.parent must be a string")
    return True


def _check_items(manifest: dict[str, Any], topics_declared: bool, errors: list[str]) -> None:
    for collection in COLLECTIONS:
        if collection not in manifest:
            continue
        values = manifest[collection]
        if not isinstance(values, list):
            errors.append(f"{collection} must be an array")
            continue
        for index, item in enumerate(values):
            where = f"{collection}[{index}]"
            if not isinstance(item, dict):
                errors.append(f"{where} must be an object")
                continue
            # Projecting a topic collects these ids into a set.
            if "id" in item and not isinstance(item["id"], str):
                errors.append(f"{where}.id must be a string")
            _check_item_topics(item, where, topics_declared, errors)
            _check_members(item.get("members"), where, topics_declared, errors)


def _check_members(members: Any, where: str, topics_declared: bool, errors: list[str]) -> None:
    if members is None:
        return
    if not isinstance(members, list):
        errors.append(f"{where}.members must be an array")
        return
    for index, membership in enumerate(members):
        member_where = f"{where}.members[{index}]"
        if not isinstance(membership, dict):
            errors.append(f"{member_where} must be an object")
            continue
        _check_item_topics(membership, member_where, topics_declared, errors)


def _check_item_topics(item: dict[str, Any], where: str, topics_declared: bool, errors: list[str]) -> None:
    if topics_declared:
        _check_str_list(item.get("topics"), f"{where}.topics", errors)
    elif "topics" in item:
        # Otherwise nothing would ever check it: validate_topics returns early and the
        # per-topic projection that normally strips the key never runs.
        errors.append(f"{where}.topics needs a manifest topics tree")


def _check_str_list(values: Any, where: str, errors: list[str]) -> None:
    if values is None:
        return
    if not isinstance(values, list) or not all(isinstance(value, str) for value in values):
        errors.append(f"{where} must be an array of strings")
