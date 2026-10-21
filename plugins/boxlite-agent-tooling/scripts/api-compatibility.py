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
from api_contract import SPEC, default_changes, git, inspect_specs, load_inputs


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
    if action == "commit":
        pending = subprocess.run(["git", "diff", "--quiet", "--", SPEC], cwd=root)
        if pending.returncode:
            raise ValueError("stage the reviewed OpenAPI before committing")
    report = {"fingerprint": inputs["fingerprint"], "base": inputs["base"], "errors": []}
    before, after, changes, breaking, detail = inspect_specs(root, inputs["before"], inputs["after"], details=action == "inspect")
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
    report["status"] = "FAIL" if report["errors"] else "PASS"
    if action == "inspect":
        report["artifacts"] = write_inspection(root, inputs, {
            "changelog": report.pop("changes"), "breaking": report.pop("breaking"), "diff": detail})
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
