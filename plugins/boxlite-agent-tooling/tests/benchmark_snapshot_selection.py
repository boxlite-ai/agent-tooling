"""Opt-in wall-time comparison; synthetic fixtures, no model or network calls."""
import argparse
import json
import platform
import statistics
import subprocess
import tempfile

from test_snapshot_selection import CAP, Reader, transcript


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repeats", type=int, default=3)
    args = parser.parse_args()
    if args.repeats < 1:
        parser.error("--repeats must be positive")
    version = subprocess.check_output(
        ["perl", "-MJSON::PP", "-e", 'print "$^V JSON::PP $JSON::PP::VERSION"'], text=True)
    report = {"platform": platform.system(), "machine": platform.machine(),
              "perl": version, "repeats": args.repeats, "cases": []}
    with tempfile.TemporaryDirectory(prefix="snapshot-benchmark-") as root:
        reader = Reader(root)
        for count in (352, 400, 472, 515):
            data = transcript(count)
            for cap in (CAP, 4 * 1024 * 1024):
                timings = {"linear": [], "current": []}
                retained = None
                for repeat in range(args.repeats):
                    outputs = {}
                    # Alternate order to reduce systematic warm-cache bias.
                    order = ("linear", "current") if repeat % 2 == 0 else ("current", "linear")
                    for mode in order:
                        result, output, _, elapsed = reader.run(data, cap, linear=mode == "linear")
                        if result.returncode:
                            raise RuntimeError(f"{mode}: {result.stderr.decode()}")
                        outputs[mode] = output
                        timings[mode].append(elapsed)
                    if outputs["linear"] != outputs["current"]:
                        raise AssertionError("snapshot bytes differ")
                    retained = json.loads(outputs["current"])["evidence_summary"]["retained"]
                case = {"seen": count, "retained": retained, "cap": cap,
                        "source_bytes": len(data), "identical_bytes": True,
                        "seconds": {mode: {"median": statistics.median(values),
                                           "min": min(values), "max": max(values)}
                                    for mode, values in timings.items()}}
                report["cases"].append(case)
                print(json.dumps(case), flush=True)
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
