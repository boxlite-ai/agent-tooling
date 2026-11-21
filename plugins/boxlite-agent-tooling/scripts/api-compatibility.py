#!/usr/bin/env python3
"""Deterministic specification audit. Shell owns persisted approvals."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / ".agents/lib"))
from api_contract import (
    SIDES, ReferenceDiscovery, default_changes, git, input_fingerprint, inspect_specs, load_inputs,
    normalize_line_endings, resolve_base,
)

API_EVIDENCE_TIMEOUT_SECONDS = 900


def write_inspection(root, inputs, reports, sources, references, scratch):
    """Publish a private, independent evidence directory for one inspection."""
    parent = scratch or git(root, "rev-parse", "--absolute-git-dir").decode().strip()
    directory = Path(tempfile.mkdtemp(prefix="api-compatibility-report-", dir=parent))
    try:
        files = {side + ".yaml": inputs[side] for side in SIDES}
        manifest = []
        for side in SIDES:
            root_name = inputs["path"]
            tree_label = sources[side].split(":", 1)[0]
            for path, content in sorted(references.get(side, {root_name: inputs[side]}).items()):
                if path == root_name:
                    filename = side + ".yaml"
                else:
                    filename = f"reference-{len(manifest)}.yaml"
                    files[filename] = content
                manifest.append({
                    "side": side, "path": path, "file": filename,
                    "source": sources[side] if path == root_name else f"{tree_label}:{path}",
                    "sha256": hashlib.sha256(content).hexdigest(),
                })
        if references or scratch:
            reports["manifest"] = manifest
        files.update({name + ".json": json.dumps(value, indent=2).encode() for name, value in reports.items()})
        for name, content in files.items():
            (directory / name).write_bytes(content)
        inspection = {"artifacts": {Path(name).stem: str(directory / name)
                                    for name in files if not name.startswith("reference-")}}
        if scratch:
            inspection["artifact_sha256"] = {name: hashlib.sha256(content).hexdigest()
                                             for name, content in files.items()}
        return inspection
    except (OSError, TypeError, ValueError):
        shutil.rmtree(directory, ignore_errors=True)
        raise


def verified_bytes(path, expected):
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"OpenAPI evidence must be a regular file: {path.name}")
    raw = path.read_bytes()
    if hashlib.sha256(raw).hexdigest() != expected:
        raise ValueError(f"OpenAPI evidence digest mismatch: {path.name}")
    return raw


def verify_evidence(path, expected):
    raw = verified_bytes(path, expected)
    report = json.loads(raw)
    for specification in report["specifications"]:
        directory = Path(specification["artifacts"]["after"]).parent
        for name, digest in specification["artifact_sha256"].items():
            if Path(name).name != name or name in ("", ".", ".."):
                raise ValueError("OpenAPI evidence artifact must have a filename")
            verified_bytes(directory / name, digest)
    return raw


def bound_source(root, binding):
    kind = binding.get("kind")
    if kind not in ("commit", "push"):
        raise ValueError("invalid OpenAPI audit source kind")
    for key, object_type in (("base", "commit"), ("head", "commit"),
                             ("candidate", "tree" if kind == "commit" else "commit")):
        value = binding.get(key)
        if not isinstance(value, str) or not re.fullmatch(r"[a-f0-9]{40}(?:[a-f0-9]{24})?", value):
            raise ValueError(f"OpenAPI audit source requires a full {key} object ID")
        if git(root, "cat-file", "-t", value).decode().strip() != object_type:
            raise ValueError(f"invalid OpenAPI audit {key} object")
    return {key: binding[key] for key in ("kind", "base", "head", "candidate")}


def evaluate(action, root, base_ref, evidence, discovery_directory, revision=None, binding=None, scratch=None):
    if action == "push" and revision is None:
        revision = git(root, "rev-parse", "--verify", "HEAD").decode().strip()
    if revision is not None and (action not in ("push", "inspect") or not re.fullmatch(r"[a-f0-9]{40}(?:[a-f0-9]{24})?", revision)):
        raise ValueError("--revision requires a full commit SHA for push or inspect")
    if binding is not None:
        source = bound_source(root, binding)
        base, candidate = source["base"], source["candidate"]
    else:
        base, candidate = resolve_base(root, base_ref, revision or "HEAD"), revision
        source = None
    specifications, snapshots = load_inputs(root, base, candidate, stage_required=action == "commit")
    report = {"base": base, "errors": [], "requires_confirmation": False, "specifications": []}
    if source:
        report["source"] = source
    if not specifications:
        report["status"] = "NOT_APPLICABLE"
        return report
    approval = evidence.get("approval", {})
    question = evidence.get("question")
    definition = Path(__file__).resolve().parents[1] / ".agents/lib/api-question.json"
    policy = json.loads(definition.read_text())
    directive = policy.get("directive") if isinstance(policy, dict) else None
    if not isinstance(directive, str) or not directive or not isinstance(question, str) or not question:
        raise ValueError("shared API compatibility question is unavailable")
    changes_requiring_approval = []
    reference_inputs = []
    discovery = ReferenceDiscovery(discovery_directory, snapshots)
    for spec in specifications:
        name = spec["path"]
        documents, changes, breaking, detail, labels, references = inspect_specs(
            root, spec, discovery, details=action == "inspect", scratch=scratch
        )
        for side in SIDES:
            for path, content in sorted(references.get(side, {}).items()):
                reference_inputs.append({
                    "root": name, "side": side, "path": path,
                    "sha256": hashlib.sha256(normalize_line_endings(content)).hexdigest(),
                })
        defaults = default_changes(*documents)
        defaults.extend(f"{c.get('operation', '')} {c.get('path', '')}: {c['text']}"
                        for c in changes if "-default-value-" in c.get("id", ""))
        item = {"path": name, "defaults": defaults}
        if action == "inspect":
            item.update(write_inspection(
                root, spec, {"changelog": changes, "breaking": breaking, "diff": detail},
                labels, references, scratch
            ))
        else:
            item.update(changes=changes, breaking=breaking)
        report["specifications"].append(item)
        if breaking:
            changes_requiring_approval.append(f"{name}: {len(breaking)} breaking API finding(s)")
        if defaults:
            changes_requiring_approval.append(
                f"{name}: existing default changes need human confirmation: " + ", ".join(defaults)
            )
    fingerprint = input_fingerprint(specifications, reference_inputs)
    report["fingerprint"] = fingerprint
    report["requires_confirmation"] = bool(changes_requiring_approval)
    approved = (isinstance(approval, dict) and approval.get("fingerprint") == fingerprint
                and approval.get("source") == "UserPromptSubmit"
                and approval.get("confirmation") == directive)
    if changes_requiring_approval and not approved:
        report["errors"] = changes_requiring_approval + [
            f"human confirmation required for change {fingerprint}: {question}"
        ]
    report["status"] = "FAIL" if report["errors"] else "PASS"
    return report


def main():
    if len(sys.argv) == 4 and sys.argv[1] == "verify-evidence":
        try:
            sys.stdout.buffer.write(verify_evidence(Path(sys.argv[2]), sys.argv[3]))
        except (OSError, ValueError, TypeError, KeyError) as error:
            print(f"api-compatibility: {error}", file=sys.stderr)
            return 1
        return 0
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("check", "inspect", "commit", "push"))
    parser.add_argument("root", type=Path)
    parser.add_argument("--base")
    parser.add_argument("--revision")
    parser.add_argument("--audit-source", type=json.loads)
    parser.add_argument("--scratch", type=Path)
    args = parser.parse_args()
    try:
        evidence = json.load(sys.stdin)
        if not isinstance(evidence, dict):
            raise ValueError("evidence must be an object")
        if (args.audit_source is None) != (args.scratch is None):
            raise ValueError("bound inspection requires a private scratch directory")
        if args.audit_source is not None and (
                args.action != "inspect" or not isinstance(args.audit_source, dict) or args.base or args.revision):
            raise ValueError("invalid bound inspection inputs")
        if args.audit_source is not None and not os.environ.get("BOXLITE_API_EVIDENCE_DEADLINE"):
            os.environ["BOXLITE_API_EVIDENCE_DEADLINE"] = str(int(time.time()) + API_EVIDENCE_TIMEOUT_SECONDS)
        with tempfile.TemporaryDirectory(prefix="api-discovery-", dir=args.scratch) as directory:
            report = evaluate(args.action, args.root.resolve(), args.base, evidence, Path(directory),
                              args.revision, args.audit_source, args.scratch)
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        report = {"status": "FAIL", "errors": [str(error)]}
    print(json.dumps(report))
    return 1 if report["status"] == "FAIL" else 0


if __name__ == "__main__":
    sys.exit(main())
