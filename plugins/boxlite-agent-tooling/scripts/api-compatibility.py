#!/usr/bin/env python3
"""Deterministic compatibility audit. Shell owns persisted evidence and approvals."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / ".agents/lib"))
from api_contract import additions, default_changes, inspect_specs, load_inputs, required_cases
from api_requests import execute


def evaluate(action, root, base, evidence):
    inputs = load_inputs(root, base)
    if inputs is None:
        return {"status": "NOT_APPLICABLE", "required": [], "passed": [], "errors": []}
    if action in ("commit", "push"):
        result = subprocess.run(["git", "diff", "--quiet", *(["HEAD"] if action == "push" else [])], cwd=root)
        untracked = subprocess.run(["git", "ls-files", "--others", "--exclude-standard"], cwd=root, capture_output=True)
        if result.returncode or untracked.returncode or untracked.stdout:
            raise ValueError("stage all reviewed sources before committing; commit them before pushing an API change")
    report = {"fingerprint": inputs["fingerprint"], "base": inputs["base"],
              "required": [], "passed": [], "errors": []}
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
                and approval.get("confirmation") in (f"maintainer confirmed: {inputs['fingerprint']} {url}",
                                                     f"maintainer confirmed: {url}"))
    if report["defaults"] and not approved:
        report["errors"].append("existing default changes need human confirmation: " + ", ".join(report["defaults"]))
    if (breaking or report["defaults"]) and not approved:
        report["errors"].append("human confirmation required for change " + inputs["fingerprint"] +
                                ": maintainer confirmed: <Notion-URL>")
    features = additions(before, after, changes)
    requirements = required_cases(inputs, features)
    report["required"] = [f"{r['sdk']['name']} {r['feature']['id']} {case}"
                          for r in requirements for case in r["cases"]]
    if action == "test" and requirements:
        with tempfile.TemporaryDirectory(prefix="api-sdk-") as directory:
            report["passed"] = execute(root, inputs, requirements, Path(directory))
        current = load_inputs(root, base)
        if current is None or current["fingerprint"] != inputs["fingerprint"]:
            raise ValueError("source changed while SDK tests ran; rerun")
    elif report["required"]:
        receipt = evidence.get("receipt", {})
        if receipt.get("fingerprint") == inputs["fingerprint"] and receipt.get("required") == report["required"]:
            report["passed"] = receipt.get("passed", [])
    if set(report["required"]) != set(report["passed"]):
        report["errors"].append("missing or stale SDK cases; run api-compatibility.sh test: " +
                                ", ".join(sorted(set(report["required"]) - set(report["passed"]))))
    report["status"] = "FAIL" if report["errors"] else "PASS"
    return report


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("check", "test", "inspect", "commit", "push"))
    parser.add_argument("root", type=Path)
    parser.add_argument("--base")
    args = parser.parse_args()
    try:
        evidence = json.load(sys.stdin)
        if not isinstance(evidence, dict):
            raise ValueError("evidence must be an object")
        report = evaluate(args.action, args.root.resolve(), args.base, evidence)
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        report = {"status": "FAIL", "errors": [str(error)], "required": [], "passed": []}
    print(json.dumps(report))
    return 1 if report["status"] == "FAIL" else 0


if __name__ == "__main__":
    sys.exit(main())
