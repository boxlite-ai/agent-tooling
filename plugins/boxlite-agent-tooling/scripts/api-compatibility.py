#!/usr/bin/env python3
"""Deterministic specification audit. Shell owns persisted approvals."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / ".agents/lib"))
from api_contract import SPEC, additions, default_changes, inspect_specs, load_inputs


def obligations(before, after, changes):
    """New optional request fields whose SDK request tests the commit/push auditor must check."""
    try:
        features = additions(before, after, changes)
    except (ValueError, KeyError, TypeError) as error:
        return [{"id": "unclassified", "note": str(error)}]
    return [{"id": f["id"], "default": f["schema"].get("default"), "hasDefault": "default" in f["schema"],
             "nullable": f["nullable"]} for f in features]


def evaluate(action, root, base, evidence):
    inputs = load_inputs(root, base)
    if inputs is None:
        return {"status": "NOT_APPLICABLE", "obligations": [], "errors": []}
    if action in ("commit", "push"):
        pending = subprocess.run(["git", "diff", "--quiet", *(["HEAD"] if action == "push" else []), "--", SPEC], cwd=root)
        if pending.returncode:
            raise ValueError("stage the reviewed OpenAPI before committing; commit it before pushing")
    report = {"fingerprint": inputs["fingerprint"], "base": inputs["base"], "errors": []}
    before, after, changes, breaking = inspect_specs(root, inputs["before"], inputs["after"])
    report["changes"] = changes
    report["breaking"] = breaking
    report["defaults"] = default_changes(before, after)
    report["defaults"].extend(f"{c.get('operation', '')} {c.get('path', '')}: {c['text']}"
                              for c in changes if "-default-value-" in c.get("id", ""))
    approval = evidence.get("approval", {})
    url = approval.get("notion", "")
    approved = (approval.get("fingerprint") == inputs["fingerprint"]
                and approval.get("source") == "UserPromptSubmit"
                and isinstance(url, str) and re.fullmatch(r"https://(?:www\.)?notion\.so/[^\s]+", url)
                and approval.get("confirmation") == f"maintainer confirmed: {url}")
    if report["defaults"] and not approved:
        report["errors"].append("existing default changes need human confirmation: " + ", ".join(report["defaults"]))
    if (breaking or report["defaults"]) and not approved:
        report["errors"].append("human confirmation required for change " + inputs["fingerprint"] +
                                ": maintainer confirmed: <Notion-URL>")
    report["obligations"] = obligations(before, after, changes)
    report["status"] = "FAIL" if report["errors"] else "PASS"
    return report


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("check", "inspect", "commit", "push"))
    parser.add_argument("root", type=Path)
    parser.add_argument("--base")
    args = parser.parse_args()
    try:
        evidence = json.load(sys.stdin)
        if not isinstance(evidence, dict):
            raise ValueError("evidence must be an object")
        report = evaluate(args.action, args.root.resolve(), args.base, evidence)
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        report = {"status": "FAIL", "errors": [str(error)], "obligations": []}
    print(json.dumps(report))
    return 1 if report["status"] == "FAIL" else 0


if __name__ == "__main__":
    sys.exit(main())
