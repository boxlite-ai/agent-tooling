#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
import traceback
from pathlib import Path
from typing import Any, Sequence

from validator.call_graph import validate_call_graph
from validator.changes import validate_changes, validate_fixes_line
from validator.consistency import validate_consistency
from validator.document import attach_topic, parse_document
from validator.mermaid import validate_mermaid
from validator.models import Check, StateBlock, ValidationContext
from validator.sequence import validate_sequence_source_labels
from validator.shape import validate_shape
from validator.source import validate_manifest, validate_source_evidence
from validator.topics import ROOT_TOPIC, declared_topics, filter_manifest, topic_ids, validate_topics


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Validate source-grounded BoxLite diagrams")
    parser.add_argument("--repo", required=True, type=Path)
    parser.add_argument("--document", required=True, type=Path)
    parser.add_argument("--evidence", required=True, type=Path)
    parser.add_argument("--report", required=True, type=Path)
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        return _validate(args)
    except Exception as error:  # noqa: BLE001 - the report is the tool's contract
        # Callers are told to read validation.json and fix what it lists, so an
        # unexpected failure has to arrive there too rather than only on stderr.
        traceback.print_exc()
        _write_report(args.report, {
            "valid": False,
            "exit_code": 1,
            "summary": {"pass": 0, "fail": 1, "error": 0},
            "checks": [{
                "name": "internal.error",
                "status": "fail",
                "message": f"validator failed before finishing: {error!r}",
                "evidence": [],
            }],
            "artifacts": [],
        })
        return 1


def _validate(args: argparse.Namespace) -> int:
    repo = args.repo.resolve()
    try:
        manifest = json.loads(args.evidence.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        report = {
            "valid": False,
            "exit_code": 1,
            "summary": {"pass": 0, "fail": 1, "error": 0},
            "checks": [{"name": "manifest.read", "status": "fail", "message": str(error), "evidence": []}],
            "artifacts": [],
        }
        _write_report(args.report, report)
        return 1

    # Whole-document concerns run once; each topic is then validated on its own
    # projection of the manifest, so the per-topic validators stay topic-unaware.
    shared = _context(repo, args, manifest)
    per_topic: list[Check] = []
    artifacts: list[Path] = []
    text, blocks_by_topic = "", {}

    # validate_topics, filter_manifest, and parse_document all read the manifest
    # before validate_manifest does; the type gate is what lets them trust it.
    nested = False
    if validate_shape(shared):
        validate_topics(shared)
        if not shared.has_failures:
            nested = bool(declared_topics(manifest))
            text, blocks_by_topic = parse_document(shared)

    # validate_manifest runs whatever happened above, so manifest.shape stays the
    # standing complaint it has always been.
    parsed = bool(blocks_by_topic) or not shared.has_failures
    for topic in topic_ids(manifest) if nested else [ROOT_TOPIC]:
        ctx = _context(repo, args, filter_manifest(manifest, topic) if nested else manifest)
        ctx.nested = nested
        ctx.source_windows = shared.source_windows
        ctx.remote_issues = shared.remote_issues
        ctx.remote_prs = shared.remote_prs
        _validate_topic(ctx, text, blocks_by_topic.get(topic, {}), parsed)
        per_topic += [_labelled(check, topic if nested else None) for check in ctx.checks]
        artifacts += ctx.artifacts

    if parsed and not any(
        check.name.endswith("manifest.shape") and check.status == "fail" for check in per_topic
    ):
        validate_fixes_line(shared, text)

    checks = list(shared.checks) + per_topic
    exit_code = 2 if any(check.status == "error" for check in checks) else (
        1 if any(check.status == "fail" for check in checks) else 0
    )
    summary = {status: sum(check.status == status for check in checks) for status in ("pass", "fail", "error")}
    report = {
        "valid": exit_code == 0,
        "exit_code": exit_code,
        "summary": summary,
        "checks": [check.to_dict() for check in checks],
        "artifacts": [str(path) for path in artifacts],
    }
    _write_report(args.report, report)
    return exit_code


def _validate_topic(
    ctx: ValidationContext,
    text: str,
    blocks: dict[tuple[str, str], StateBlock],
    parsed: bool,
) -> None:
    validate_manifest(ctx)
    if not parsed:
        # The document was never read, so every check below would judge an empty
        # diagram and bury the real failure under invented ones.
        return
    if any(check.name == "manifest.shape" and check.status == "fail" for check in ctx.checks):
        return
    attach_topic(ctx, text, blocks)
    validate_source_evidence(ctx)
    validate_mermaid(ctx)
    validate_sequence_source_labels(ctx)
    validate_call_graph(ctx)
    validate_changes(ctx)
    validate_consistency(ctx)


def _context(repo: Path, args: argparse.Namespace, manifest: Any) -> ValidationContext:
    return ValidationContext(
        repo=repo,
        document_path=args.document.resolve(),
        evidence_path=args.evidence.resolve(),
        report_path=args.report.resolve(),
        manifest=manifest,
    )


def _labelled(check: Check, topic: str | None) -> Check:
    if topic is None:
        return check
    return Check(f"{topic}/{check.name}", check.status, check.message, check.evidence)


def _write_report(path: Path, report: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            stream.write(json.dumps(report, indent=2, sort_keys=True) + "\n")
        temporary.replace(path)
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise


if __name__ == "__main__":
    sys.exit(main())
