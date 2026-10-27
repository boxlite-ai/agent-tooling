"""Exact-byte differential checks and bounded-work regression for issue #264."""
import hashlib
import json
import math
import os
from pathlib import Path
import random
import subprocess
import tempfile
import time
import unittest


TEST_DIR = Path(__file__).resolve().parent
LIBRARY = TEST_DIR.parent / ".agents/lib/verdict-audit-state.sh"
FIXTURES = TEST_DIR / "snapshot_selection"
CAP = 262144


def transcript(count, host="claude", mixed=False, claim="Synthetic claim: checks passed."):
    """Generate public-shaped records, never local conversation content."""
    records = [{"role": "user", "content": "Inspect the synthetic fixture."}]

    def assistant(text):
        content = {"role": "assistant", "content": [{"type": "text", "text": text}]}
        records.append({"type": "assistant", "message": content} if host == "claude"
                       else {"type": "response_item", "payload": content})

    assistant(claim)
    for index in range(count):
        size = (0, 9, 99, 999, 2048, 5000)[index % 6] if mixed else 700
        payload = ("证据🙂\n\t\"\\" if mixed else "x") * size
        if host == "claude":
            tool = {"type": "tool_use", "id": f"tool-{index}",
                    "name": "synthetic", "input": {"text": payload}}
            if index % 2:
                tool = {"type": "tool_result", "tool_use_id": f"tool-{index}",
                        "content": payload, "is_error": index % 7 == 0}
            records.append({"type": "user" if index % 2 else "assistant",
                            "message": {"content": [tool]}})
        else:
            tool = {"type": "function_call", "call_id": f"tool-{index}",
                    "name": "synthetic", "arguments": payload}
            if index % 2:
                tool = {"type": "function_call_output", "call_id": f"tool-{index}",
                        "output": payload}
            records.append({"type": "response_item", "payload": tool})
        if index % 41 == 40:
            assistant(f"Synthetic checkpoint {index}.")
    assistant("Synthetic final claim.")
    return ("\n".join(json.dumps(row, ensure_ascii=False) for row in records) + "\n").encode()


class Reader:
    def __init__(self, root):
        self.root = Path(root)
        self.serial = 0
        # Freeze only the old selection algorithm; parsing/building still crosses
        # the production boundary, including hashing and exclusive publication.
        source = LIBRARY.read_text()
        start = source.index("    my $keep_tools = scalar @tool_entries;")
        end = source.index("    exit 1 if length($output) + 1 > $max_snapshot;", start)
        self.linear = self.root / "linear-reader.sh"
        self.linear.write_text(source[:start] + (FIXTURES / "linear-selector.pl").read_text()
                               + source[end:])

    def run(self, data, cap=CAP, linear=False, probe=False):
        self.serial += 1
        source = self.root / "transcript.jsonl"
        source.write_bytes(data)
        destination = self.root / f"snapshot-{self.serial}.json"
        trace = self.root / f"trace-{self.serial}.txt"
        env = os.environ.copy()
        if probe:
            env["PERL5LIB"] = str(FIXTURES)
            env["PERL5OPT"] = "-MSnapshotProbe"
            env["SNAPSHOT_PROBE_LOG"] = str(trace)
        started = time.perf_counter()
        result = subprocess.run(
            ["bash", "-c", 'source "$1"; verdict_audit_snapshot_final_turn "$2" "$3" 67108864 "$4"',
             "snapshot-test", str(self.linear if linear else LIBRARY),
             str(source), str(destination), str(cap)],
            capture_output=True, env=env, timeout=25,
        )
        elapsed = time.perf_counter() - started
        output = destination.read_bytes() if destination.exists() else None
        attempts = [tuple(map(int, line.split())) for line in trace.read_text().splitlines()] \
            if trace.exists() else []
        return result, output, attempts, elapsed


class SnapshotSelectionTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="snapshot-selection-")
        self.addCleanup(directory.cleanup)
        self.reader = Reader(directory.name)

    def compare(self, data, cap, expected_kept=None):
        old, old_bytes, _, _ = self.reader.run(data, cap, linear=True)
        new, new_bytes, _, _ = self.reader.run(data, cap)
        self.assertEqual(new.returncode, old.returncode, new.stderr)
        self.assertEqual(new.stdout, old.stdout)
        self.assertEqual(new_bytes, old_bytes)
        if new.returncode:
            self.assertIsNone(new_bytes, "failure must retract the destination")
            return None
        self.assertEqual(new.stderr, b"")
        self.assertEqual(new.stdout, b"")
        self.assertLessEqual(len(new_bytes), cap)
        self.assertTrue(new_bytes.endswith(b"\n"))
        value = json.loads(new_bytes)
        self.assertEqual(value["source_sha256"], hashlib.sha256(data).hexdigest())
        if expected_kept is not None:
            self.assertEqual(value["evidence_summary"]["retained"], expected_kept)
        tools = [r["tools"][0]["id"] for r in value["records"] if r["kind"] == "tool"]
        self.assertEqual(tools, [f"tool-{i}" for i in range(len(tools))])
        return value

    def test_long_turn_has_logarithmically_bounded_manifest_encodings(self):
        data = transcript(515)
        result, output, attempts, _ = self.reader.run(data, probe=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        value = json.loads(output)
        self.assertEqual(value["evidence_summary"]["seen"], 515)
        self.assertGreater(value["evidence_summary"]["omitted"], 200)
        self.assertFalse(value["truncated"])
        limit = 4 + math.ceil(math.log2(515))
        self.assertLessEqual(len(attempts), limit,
                             f"manifest encodings grew with omitted tools: {len(attempts)} > {limit}")

    def test_boundaries_match_linear_scan_and_candidate_sizes_increase(self):
        for host, mixed, count in (("claude", False, 12), ("codex", True, 12),
                                   ("claude", True, 101)):
            data = transcript(count, host, mixed)
            result, _, attempts, _ = self.reader.run(data, 1, linear=True, probe=True)
            self.assertNotEqual(result.returncode, 0)
            # Cap 1 visits all three preview stages, then every shorter prefix.
            candidates = [row for row in attempts[2:] if not row[1]]
            self.assertEqual([row[0] for row in candidates], list(range(count, -1, -1)))
            sizes = {kept: size for kept, _, size in candidates}
            self.assertTrue(all(sizes[k] < sizes[k + 1] for k in range(count)))
            selections = range(count) if count == 12 else (0, 1, 9, 10, 90, 91, 99, 100)
            for kept in selections:
                # max_snapshot_bytes itself is serialized; solve its decimal width.
                cap = sizes[kept]
                while cap != sizes[kept] - 1 + len(str(cap)):
                    cap = sizes[kept] - 1 + len(str(cap))
                for delta in (-1, 0, 1):
                    with self.subTest(host=host, count=count, kept=kept, delta=delta):
                        self.compare(data, cap + delta, kept if delta >= 0 else None)
            # Each preview stage's exact fit must retain every tool, unchanged.
            for _, _, size in attempts[:3]:
                cap = size
                while cap != size - 1 + len(str(cap)):
                    cap = size - 1 + len(str(cap))
                self.compare(data, cap, count)

    def test_empty_single_claim_overflow_and_invalid_turns(self):
        for count in (0, 1):
            data = transcript(count)
            self.compare(data, CAP, count)
            self.compare(data, 1)
        data = transcript(10, claim="whole claim " * 2000)
        value = self.compare(data, 1000, 0)
        self.assertTrue(value["truncated"])
        self.assertEqual(value["records"], [])
        self.assertGreater(value["claim_bytes"], 1000)
        for data in (b'{"role":"assistant",\n', b'\0\n'):
            self.compare(data, CAP)

    def test_payload_preview_boundary_without_claims(self):
        records = []
        for index, size in enumerate((2047, 2048, 2049)):
            tool = {"type": "function_call_output", "call_id": f"tool-{index}", "output": ""}
            overhead = len(json.dumps(tool, sort_keys=True, separators=(",", ":")).encode())
            tool["output"] = "x" * (size - overhead)
            records.append(tool)
        data = ("\n".join(json.dumps(tool) for tool in records) + "\n").encode()
        value = self.compare(data, CAP, 3)
        tools = [r["tools"][0] for r in value["records"]]
        self.assertEqual([tool["payload_bytes"] for tool in tools], [2047, 2048, 2049])
        self.assertEqual([tool["content_truncated"] for tool in tools], [False, False, True])
        for cap in (1000, 3000, 5000):
            self.compare(data, cap)

    def test_seeded_caps_and_interleaved_claims(self):
        rng = random.Random(264)
        for host in ("claude", "codex"):
            data = transcript(45, host, mixed=True)
            for cap in [CAP, 1000, 10000] + [rng.randrange(1000, 80000) for _ in range(5)]:
                with self.subTest(host=host, cap=cap):
                    value = self.compare(data, cap)
                    if value and not value["truncated"]:
                        claims = [t for r in value["records"] if r["kind"] == "assistant"
                                  for t in r["texts"]]
                        self.assertEqual(claims, ["Synthetic claim: checks passed.",
                                                 "Synthetic checkpoint 40.", "Synthetic final claim."])


if __name__ == "__main__":
    unittest.main(verbosity=2)
