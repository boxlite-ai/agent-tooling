"""Read-only loop diagnostics; no test manufactures audit permission."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

PLUGIN = Path(__file__).resolve().parents[2]


def model(expression, value, check=True):
    return subprocess.run(["jq", "-ce", "-L", str(PLUGIN / ".agents/lib"),
                           'include "audit-loop"; ' + expression],
                          input=json.dumps(value), text=True, capture_output=True,
                          timeout=10, check=check)


def frame(kind, *identities, severity="high"):
    return {"kind": kind, "findings": [{"id": identity, "severity": severity} for identity in identities]}


class Classification(unittest.TestCase):
    def classify(self, *rounds):
        return json.loads(model("audit_loop_classify", {"rounds": rounds, "history_complete": True}).stdout)

    def test_patterns_and_startup(self):
        cases = [([], "initial"), ([frame("FAIL", "F1")], "initial"),
                 ([frame("ERROR")], "error"), ([frame("ERROR"), frame("ERROR")], "infra"),
                 ([frame("PASS")], "complete"), ([frame("CANCELED")], "canceled"),
                 ([frame("IN_PROGRESS")], "partial"), ([frame("OVERRIDDEN")], "overridden"),
                 ([frame("FAIL", "F1", "F2"), frame("FAIL", "F1")], "converging"),
                 ([frame("FAIL", "F1"), frame("FAIL", "F1", "F2")], "stalled"),
                 ([frame("FAIL", "F1"), frame("FAIL", "F2")], "churning"),
                 ([frame("FAIL", "F1"), frame("ERROR", "F1"), frame("FAIL", "F1")], "stalled"),
                 ([frame("ERROR"), frame("FAIL", "F1"), frame("ERROR", "F1")], "error")]
        for rounds, expected in cases:
            with self.subTest(expected=expected, rounds=rounds):
                self.assertEqual(self.classify(*rounds)["pattern"], expected)

    def test_critical_finding_survives_error_frames(self):
        result = self.classify(*(frame(kind, "F1", severity="critical") for kind in ("FAIL", "ERROR", "ERROR")))
        self.assertEqual(result["pattern"], "infra")
        self.assertEqual(result["critical_ids"], ["F1"])
        self.assertEqual(result["blocking_count"], 1)

    def test_invalid_and_boundary_views(self):
        value = {"rounds": [frame("ERROR")] * 16, "history_complete": True}
        self.assertEqual(json.loads(model("audit_loop_classify", value).stdout)["pattern"], "infra")
        for changed in ({**value, "rounds": value["rounds"] + [frame("ERROR")]},
                        {**value, "history_complete": "true"},
                        {**value, "rounds": [{"kind": "BOGUS", "findings": []}]},
                        {**value, "rounds": [frame("FAIL", "F1", severity="low")]},
                        {**value, "rounds": [frame("FAIL", "F1", "F1")]}):
            with self.subTest(value=changed):
                self.assertNotEqual(model("audit_loop_classify", changed, check=False).returncode, 0)

    def test_normalized_finding_capacity(self):
        value = {"rounds": [frame("FAIL", *(f"F{i}" for i in range(144)))], "history_complete": True}
        self.assertEqual(json.loads(model("audit_loop_classify", value).stdout)["blocking_count"], 144)
        value["rounds"][0]["findings"].append({"id": "extra", "severity": "high"})
        self.assertNotEqual(model("audit_loop_classify", value, check=False).returncode, 0)

    def test_opaque_history_retains_a_critical_gap(self):
        history = {"registry": [], "attempts": [
            {"id": "a1", "outcome": {"verdict": "FAIL", "evidence": "legacy blocker"}},
            {"id": "a2", "outcome": {"verdict": "ERROR", "evidence": "transport failure"}},
            {"id": "a3", "outcome": {"verdict": "ERROR", "evidence": "transport failure"}}]}
        result = json.loads(model("audit_loop_history_view | audit_loop_classify", history).stdout)
        self.assertEqual(result["pattern"], "infra")
        self.assertEqual(result["critical_ids"], ["untracked:a1"])
        self.assertFalse(result["history_complete"])

    def test_design_legacy_and_recorded_progress(self):
        old = {"verdict": "FAIL", "findings": ["unprefixed blocker"], "failures": ["a1", "a2"]}
        result = json.loads(model("audit_loop_design_view | audit_loop_classify", old).stdout)
        self.assertFalse(result["history_complete"])
        self.assertEqual(result["critical_ids"], ["unprefixed blocker"])
        old = {"verdict": "FAIL", "findings": ["high: F1", "high: F2"], "failures": ["a1"]}
        progress = json.loads(model('audit_loop_design_record("FAIL"; ["high: F1"])', old).stdout)
        result = json.loads(model("audit_loop_classify", progress).stdout)
        self.assertEqual(result["pattern"], "converging")
        self.assertTrue(result["history_complete"])

    def test_design_record_bounds_and_request_adapter(self):
        expression = '''include "design-audit";
          da_empty("/fixture"; "main")
          | da_record({verdict:"FAIL",findings:["high: F1","high: F2"],advisories:[]}; "issue"; "a")
          | da_record({verdict:"FAIL",findings:["high: F1"],advisories:[]}; "issue"; "b")
          | da_request("/fixture"; "issue"; "b"; "history")'''
        result = json.loads(model(expression, None).stdout)
        self.assertEqual(result["recovery"]["pattern"], "converging")
        self.assertEqual(result["fails"], 2)
        # The existing design gate still pauses on a repeated finding.
        self.assertFalse(result["reflection_due"])
        self.assertTrue(result["blocked"])
        progress = {"rounds": [frame("FAIL", "high: F1")] * 16, "history_complete": True}
        state = {"verdict": "FAIL", "progress": progress}
        result = json.loads(model('audit_loop_design_record("FAIL"; ["high: F2"])', state).stdout)
        self.assertEqual(len(result["rounds"]), 16)
        self.assertFalse(result["history_complete"])


class HistoryInspection(unittest.TestCase):
    def test_full_registry_and_opaque_gap_remain_inspectable(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "history.json"
            context = {"repo_root": directory, "session": "capacity-fixture", "epoch": "1",
                       "branch": "main", "gate": "verdict"}

            def transition(operation, **payload):
                result = subprocess.run(
                    ["bash", str(PLUGIN / "scripts/audit-reflection.sh"), operation, str(state)],
                    input=json.dumps({"context": context, **payload}),
                    text=True, capture_output=True, timeout=20, check=True)
                return json.loads(result.stdout)

            for batch in range(5):
                identity = f"a{batch}"
                current = transition("status")
                failed = [a["id"] for a in current["attempts"]
                          if a["outcome"] and a["outcome"]["verdict"] in ("FAIL", "ERROR")]
                if len(failed) >= 2:
                    transition("submit", reflection={"history_hash": current["history_hash"],
                        "failure_ids": failed, "diagnosis": "accepted findings fill the registry",
                        "previous_fixes_failed_because": "opaque history still needs assessment",
                        "changed_approach": "inspect accepted registry capacity",
                        "checks": [{"command": "audit-reflection.sh status STATE",
                            "expected": "accepted registry count", "observed": str(len(current["registry"])),
                            "evidence": "production status output"}], "auditor_gaps": []})
                prepared = transition("prepare", attempt={"id": identity,
                    "binding": {"head": identity}, "snapshot": {"diff": "capacity fixture"},
                    "deadline": 4102444800})
                outcome = {"verdict": "FAIL", "evidence": "opaque legacy blocker"}
                if batch:
                    outcome["history_review"] = {"attempt_id": identity,
                        "history_hash": prepared["history_hash"],
                        "dispositions": [{"id": r["id"], "status": "open", "evidence": "fixture check"}
                                         for r in prepared["registry"]],
                        "findings": [{"id": "NEW", "severity": "high",
                            "invariant": f"worker {batch}-{i} closes", "behavior": "leaked worker",
                            "criterion": "worker exits", "evidence": "fixture check",
                            "origin": "introduced", "origin_evidence": "new fixture worker",
                            "review_gap": "", "review_change": "", "reopening": None,
                            "conflict": None, "criterion_change": None} for i in range(32)],
                        "coverage": {"reviewed": ["diff"], "unread": []}}
                reflection_hash = prepared["attempts"][-1]["reflection_hash"]
                if reflection_hash:
                    outcome["reflection_review"] = {"reflection_hash": reflection_hash,
                        "assessment": "sufficient", "evidence": "production status output",
                        "auditor_assessment": "the fixture inspected accepted registry capacity"}
                recorded = transition("record", id=identity, outcome=outcome)
            self.assertEqual(len(recorded["registry"]), 128)
            inspected = model("audit_loop_history_view | audit_loop_classify", recorded, check=False)
            self.assertEqual(inspected.returncode, 0, inspected.stderr)
            result = json.loads(inspected.stdout)
            self.assertEqual(result["critical_ids"], ["untracked:a0"])
            self.assertEqual(result["blocking_count"], 129)

    def test_opaque_failure_survives_a_structured_high_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "history.json"
            context = {"repo_root": directory, "session": "legacy-fixture", "epoch": "1",
                       "branch": "main", "gate": "verdict"}

            def transition(operation, **payload):
                result = subprocess.run(
                    ["bash", str(PLUGIN / "scripts/audit-reflection.sh"), operation, str(state)],
                    input=json.dumps({"context": context, **payload}),
                    text=True, capture_output=True, timeout=20, check=True)
                return json.loads(result.stdout)

            for identity in ("a1", "a2"):
                prepared = transition("prepare", attempt={"id": identity,
                    "binding": {"head": identity}, "snapshot": {"diff": "candidate"},
                    "deadline": 4102444800})
                outcome = {"verdict": "FAIL", "evidence": "opaque legacy blocker"}
                if identity == "a2":
                    outcome["history_review"] = {"attempt_id": identity,
                        "history_hash": prepared["history_hash"], "dispositions": [],
                        "findings": [{"id": "NEW", "severity": "high",
                            "invariant": "worker closes", "behavior": "leaked worker",
                            "criterion": "worker exits", "evidence": "test output",
                            "origin": "missed_earlier", "origin_evidence": "prior snapshot",
                            "review_gap": "cleanup not examined", "review_change": "trace cleanup",
                            "reopening": None, "conflict": None, "criterion_change": None}],
                        "coverage": {"reviewed": ["diff"], "unread": []}}
                recorded = transition("record", id=identity, outcome=outcome)
            result = json.loads(model("audit_loop_history_view | audit_loop_classify", recorded).stdout)
            self.assertEqual(result["critical_ids"], ["untracked:a1"])
            self.assertEqual(result["blocking_count"], 2)
            self.assertEqual(result["pattern"], "stalled")
            self.assertFalse(result["history_complete"])

    def test_two_errors_are_infra(self):
        for name in ("commit", "push", "verdict"):
            with self.subTest(gate=name):
                self.check_two_errors(name)

    def check_two_errors(self, name):
        with tempfile.TemporaryDirectory() as directory:
            root = str(Path(directory).resolve())
            context = {"repo_root": root, "session": "loop-fixture", "epoch": "1",
                       "branch": "main", "gate": name}

            def gate(operation, identity="", payload=None):
                result = subprocess.run(
                    ["bash", str(PLUGIN / "scripts/audit-reflection-gate.sh"),
                     json.dumps(context), operation, identity],
                    input=json.dumps({} if payload is None else payload),
                    text=True, capture_output=True, timeout=20, check=True)
                return json.loads(result.stdout)

            for identity in ("a1", "a2"):
                gate("prepare", identity, {"binding": {"head": identity},
                     "snapshot": {"diff": "candidate"}, "deadline": 4102444800})
                gate("error", identity, "auditor transport failed")
            inspected = gate("inspect")
            self.assertEqual(inspected.get("recovery", {}).get("pattern"), "infra")
            self.assertTrue(inspected["reflection_due"])
            self.assertEqual([a["outcome"]["verdict"] for a in inspected["state"]["attempts"]],
                             ["ERROR", "ERROR"])


if __name__ == "__main__":
    unittest.main()
