#!/usr/bin/env python3
"""Deterministic specification audit. Shell owns persisted approvals."""
import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / ".agents/lib"))
from api_contract import SKIP_CONFIRMATION, default_changes, git, inspect_specs, load_inputs


def write_inspection(root, inputs, reports):
    """Publish a private, independent evidence directory for one inspection."""
    git_dir = git(root, "rev-parse", "--absolute-git-dir").decode().strip()
    directory = Path(tempfile.mkdtemp(prefix="api-compatibility-report-", dir=git_dir))
    try:
        files = {"before.yaml": inputs["before"], "after.yaml": inputs["after"]}
        files.update({name + ".json": json.dumps(value, indent=2).encode() for name, value in reports.items()})
        for name, content in files.items():
            (directory / name).write_bytes(content)
        return {Path(name).stem: str(directory / name) for name in files}
    except (OSError, TypeError, ValueError):
        shutil.rmtree(directory, ignore_errors=True)
        raise


def evaluate(action, root, base, evidence, revision=None):
    if action == "push" and revision is None:
        revision = git(root, "rev-parse", "--verify", "HEAD").decode().strip()
    if revision is not None and (action not in ("push", "inspect") or not re.fullmatch(r"[a-f0-9]{40}(?:[a-f0-9]{24})?", revision)):
        raise ValueError("--revision requires a full commit SHA for push or inspect")
    inputs = load_inputs(root, base, revision)
    if inputs is None:
        return {"status": "NOT_APPLICABLE", "errors": []}
    report = {"fingerprint": inputs["fingerprint"], "base": inputs["base"], "errors": [],
              "requires_confirmation": False, "specifications": []}
    approval = evidence.get("approval", {})
    approved = (isinstance(approval, dict) and approval.get("fingerprint") == inputs["fingerprint"]
                and approval.get("source") == "UserPromptSubmit"
                and approval.get("confirmation") == SKIP_CONFIRMATION)
    for spec in inputs["specifications"]:
        name = spec["path"]
        if action == "commit":
            pending = subprocess.run(["git", "diff", "--quiet", "--", ":(literal)" + name], cwd=root)
            if pending.returncode:
                raise ValueError(f"{name}: stage the reviewed OpenAPI before committing")
        before, after, changes, breaking, detail = inspect_specs(root, spec["before"], spec["after"], details=action == "inspect")
        defaults = default_changes(before, after)
        defaults.extend(f"{c.get('operation', '')} {c.get('path', '')}: {c['text']}"
                        for c in changes if "-default-value-" in c.get("id", ""))
        item = {"path": name, "defaults": defaults}
        if action == "inspect":
            item["artifacts"] = write_inspection(root, spec, {"changelog": changes, "breaking": breaking, "diff": detail})
        else:
            item.update(changes=changes, breaking=breaking)
        report["specifications"].append(item)
        if breaking or defaults:
            report["requires_confirmation"] = True
        if not approved:
            if breaking:
                report["errors"].append(f"{name}: {len(breaking)} breaking API finding(s)")
            if defaults:
                report["errors"].append(f"{name}: existing default changes need human confirmation: " + ", ".join(defaults))
    if report["requires_confirmation"] and not approved:
        report["errors"].append("human confirmation required for change " + inputs["fingerprint"] +
                                ": recommend discussing these breaking/default changes in a GitHub issue. "
                                "Do you want to skip this compatibility gate? To confirm, submit exactly: " + SKIP_CONFIRMATION)
    report["status"] = "FAIL" if report["errors"] else "PASS"
    return report


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("check", "inspect", "commit", "push"))
    parser.add_argument("root", type=Path)
    parser.add_argument("--base")
    parser.add_argument("--revision")
    args = parser.parse_args()
    try:
        evidence = json.load(sys.stdin)
        if not isinstance(evidence, dict):
            raise ValueError("evidence must be an object")
        report = evaluate(args.action, args.root.resolve(), args.base, evidence, args.revision)
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        report = {"status": "FAIL", "errors": [str(error)]}
    print(json.dumps(report))
    return 1 if report["status"] == "FAIL" else 0


if __name__ == "__main__":
    sys.exit(main())
