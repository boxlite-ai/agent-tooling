#!/usr/bin/env python3
"""Check a hand-placed figure spec against its evidence manifest. Exit 0 clean, 1 findings, 2 unusable input."""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from figure.check import check_figure, validate_spec  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--spec", required=True, type=Path, help="figure.json")
    parser.add_argument("--evidence", required=True, type=Path, help="evidence.json the figure draws from")
    parser.add_argument("--report", type=Path, help="write findings as JSON here")
    args = parser.parse_args()
    try:
        spec = json.loads(args.spec.read_text(encoding="utf-8"))
        manifest = json.loads(args.evidence.read_text(encoding="utf-8"))
        if problems := validate_spec(spec):
            raise ValueError("; ".join(problems))
        findings = check_figure(spec, manifest)
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"check_figure: cannot check {args.spec}: {error}", file=sys.stderr)
        return 2
    if args.report:
        args.report.write_text(json.dumps({"valid": not findings, "findings": findings}, indent=2), encoding="utf-8")
    for finding in findings:
        print(f"{finding['kind']}: {finding['where']}: {finding['detail']}")
    print(f"{len(findings)} finding(s)" if findings else "figure passes")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
