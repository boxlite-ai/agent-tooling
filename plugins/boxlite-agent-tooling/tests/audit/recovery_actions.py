"""New recovery contract: reservations and overlays never manufacture PASS."""
import copy
import json
from pathlib import Path
import subprocess
import unittest

PLUGIN = Path(__file__).resolve().parents[2]


def model(expression, value, check=True):
    return subprocess.run(
        ["jq", "-ce", "-L", str(PLUGIN / ".agents/lib"),
         'include "audit-recovery"; ' + expression],
        input=json.dumps(value), text=True, capture_output=True, timeout=10, check=check)


def frame(*identities, severity="high", kind="FAIL"):
    return {"kind": kind, "findings": [{"id": value, "severity": severity} for value in identities]}


def candidate(*rounds):
    return {"view": {"rounds": list(rounds), "history_complete": True},
            "recovery": None, "exhausted": False}


class RecoveryActions(unittest.TestCase):
    assignment = {"task_id": "a" * 32, "source_sha256": "b" * 64, "deadline": 1000}

    def plan(self, value):
        return json.loads(model("audit_recovery_next(100)", value).stdout)

    def reserve(self, value, kind):
        return json.loads(model(
            f'audit_recovery_reserve("{kind}"; {json.dumps(self.assignment)}; 100)', value).stdout)

    def test_selection_and_each_once_per_loop(self):
        for before, after, action in [(frame("F1"), frame("F1"), "referee"),
                                      (frame("F1"), frame("F2"), "shrink")]:
            with self.subTest(action=action):
                value = candidate(before, after)
                self.assertEqual(self.plan(value), action)
                reserved = self.reserve(value, action)
                self.assertEqual(reserved["recovery"]["loop_id"], self.assignment["task_id"])
                self.assertEqual(self.plan(reserved), "pending")
                self.assertNotEqual(model(
                    f'audit_recovery_reserve("{action}"; {json.dumps(self.assignment)}; 100)',
                    reserved, check=False).returncode, 0)
                # Expiry consumes the exit; it never permits another launch.
                self.assertEqual(json.loads(model("audit_recovery_next(1001)", reserved).stdout), "stuck")

    def test_critical_and_caps_precede_reservation(self):
        value = candidate(frame("F1"), frame("F1", severity="critical"))
        self.assertEqual(self.plan(value), "critical")
        value["exhausted"] = True
        self.assertEqual(self.plan(value), "critical")
        value["view"]["rounds"][-1] = frame("F1")
        self.assertEqual(self.plan(value), "capped")
        self.assertNotEqual(model(
            f'audit_recovery_reserve("referee"; {json.dumps(self.assignment)}; 100)',
            value, check=False).returncode, 0)

    def test_result_is_an_overlay_over_original_evidence(self):
        value = self.reserve(candidate(frame("F1", "F2"), frame("F1", "F2")), "referee")
        original = copy.deepcopy(value["view"])
        result = [{"id": "F1", "status": "upheld", "evidence": "source.py:4 leak remains"},
                  {"id": "F2", "status": "retracted", "evidence": "source.py:9 cleanup closes it"}]
        completed = json.loads(model(
            f'audit_recovery_finish("referee"; "{"a" * 32}"; "{"b" * 64}"; {json.dumps(result)})',
            value).stdout)
        self.assertEqual(completed["view"], original)
        effective = json.loads(model("audit_recovery_effective_view", completed).stdout)
        self.assertEqual(effective["rounds"][-1]["findings"], [frame("F1")["findings"][0]])
        self.assertEqual(self.plan(completed), "none")
        completed["view"]["rounds"].append(frame("F1"))
        self.assertEqual(self.plan(completed), "stuck")
        self.assertNotIn("verdict", completed["recovery"]["referee"])

    def test_uncited_retraction_stands_and_replay_is_rejected(self):
        value = self.reserve(candidate(frame("F1"), frame("F1")), "referee")
        result = [{"id": "F1", "status": "retracted", "evidence": "I disagree"}]
        expression = f'audit_recovery_finish("referee"; "{"a" * 32}"; "{"b" * 64}"; {json.dumps(result)})'
        completed = json.loads(model(expression, value).stdout)
        self.assertEqual(self.plan(completed), "stuck")
        self.assertEqual(completed["recovery"]["referee"]["result"][0]["status"], "upheld")
        self.assertNotEqual(model(expression, completed, check=False).returncode, 0)

    def test_wrong_task_source_and_finding_set_grant_nothing(self):
        value = self.reserve(candidate(frame("F1"), frame("F1")), "referee")
        correct = [{"id": "F1", "status": "upheld", "evidence": "source.py:1"}]
        cases = [("c" * 32, "b" * 64, correct), ("a" * 32, "c" * 64, correct),
                 ("a" * 32, "b" * 64, []), ("a" * 32, "b" * 64, correct * 2),
                 ("a" * 32, "b" * 64, [{**correct[0], "status": "PASS"}])]
        for task, source, result in cases:
            with self.subTest(task=task, source=source, result=result):
                self.assertNotEqual(model(
                    f'audit_recovery_finish("referee"; "{task}"; "{source}"; {json.dumps(result)})',
                    value, check=False).returncode, 0)

    def test_a_critical_finding_cannot_leave_the_effective_view(self):
        value = self.reserve(candidate(frame("F1"), frame("F1")), "referee")
        value["view"]["rounds"][-1]["findings"][0]["severity"] = "critical"
        value["recovery"]["referee"]["findings"][0]["severity"] = "critical"
        result = [{"id": "F1", "status": "retracted", "evidence": "source.py:1"}]
        completed = json.loads(model(
            f'audit_recovery_finish("referee"; "{"a" * 32}"; "{"b" * 64}"; {json.dumps(result)})',
            value).stdout)
        self.assertEqual(self.plan(completed), "critical")

    def test_two_recovery_types_share_one_loop_but_separate_markers(self):
        value = self.reserve(candidate(frame("F1"), frame("F2")), "shrink")
        loop_id = value["recovery"]["loop_id"]
        # A new ordinary candidate may run after shrink; recording that audit does
        # not erase its reservation or substitute a shrink completion for review.
        value["view"]["rounds"].append(frame("F2"))
        self.assertEqual(self.plan(value), "referee")
        reserved = self.reserve(value, "referee")
        self.assertEqual(reserved["recovery"]["loop_id"], loop_id)
        self.assertIsNotNone(reserved["recovery"]["shrink"])
        self.assertIsNotNone(reserved["recovery"]["referee"])

    def test_referee_then_churn_retains_one_independent_shrink(self):
        value = self.reserve(candidate(frame("F1"), frame("F1")), "referee")
        result = [{"id": "F1", "status": "upheld", "evidence": "source.py:1"}]
        completed = json.loads(model(
            f'audit_recovery_finish("referee"; "{"a" * 32}"; "{"b" * 64}"; {json.dumps(result)})', value).stdout)
        completed["view"]["rounds"].append(frame("F2"))
        self.assertEqual(self.plan(completed), "shrink")
        reserved = self.reserve(completed, "shrink")
        self.assertEqual(reserved["recovery"]["referee"], completed["recovery"]["referee"])

    def test_malformed_records_fail_closed(self):
        original = candidate(frame("F1"), frame("F1"))
        for field, bad in [("exhausted", "false"), ("recovery", {}),
                           ("view", {"rounds": [], "history_complete": "true"})]:
            value = {**original, field: bad}
            self.assertNotEqual(model("audit_recovery_next(100)", value, check=False).returncode, 0)

    def test_shrink_completion_preserves_findings_and_grants_no_verdict(self):
        value = self.reserve(candidate(frame("F1"), frame("F2")), "shrink")
        result = {"candidate_sha256": "c" * 64, "removed_scope": ["optional display"],
                  "affected_sections": ["How it works"], "preserved_requirements": ["required retry fix"],
                  "findings": ["F2"]}
        expression = f'audit_recovery_shrink_finish("{"a" * 32}"; "{"b" * 64}"; {json.dumps(result)})'
        completed = json.loads(model(expression, value).stdout)
        self.assertEqual(completed["view"], value["view"])
        self.assertEqual(self.plan(completed), "stuck")
        self.assertNotIn("verdict", completed["recovery"]["shrink"])
        self.assertNotEqual(model(expression, completed, check=False).returncode, 0)
        for changed in ({**result, "findings": []}, {**result, "preserved_requirements": []},
                        {**result, "candidate_sha256": "b" * 64}, {**result, "removed_scope": []}):
            self.assertNotEqual(model(
                f'audit_recovery_shrink_finish("{"a" * 32}"; "{"b" * 64}"; {json.dumps(changed)})',
                value, check=False).returncode, 0)

    def test_no_permitted_reduction_consumes_the_marker(self):
        value = self.reserve(candidate(frame("F1"), frame("F2")), "shrink")
        result = {"candidate_sha256": "b" * 64, "removed_scope": [], "affected_sections": [],
                  "preserved_requirements": ["all edits are mandatory"], "findings": ["F2"]}
        completed = json.loads(model(
            f'audit_recovery_shrink_finish("{"a" * 32}"; "{"b" * 64}"; {json.dumps(result)})', value).stdout)
        self.assertEqual(self.plan(completed), "stuck")

    def test_referee_records_without_the_optional_shrink_marker_are_accepted(self):
        current = self.reserve(candidate(frame("F1"), frame("F1")), "referee")
        old = copy.deepcopy(current)
        del old["recovery"]["shrink"]
        result = model("audit_recovery_next(100)", old, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), "pending")
        self.assertNotEqual(model(
            f'audit_recovery_reserve("referee"; {json.dumps(self.assignment)}; 100)',
            old, check=False).returncode, 0)
        decisions = [{"id": "F1", "status": "upheld", "evidence": "source.py:1"}]
        completed = json.loads(model(
            f'audit_recovery_finish("referee"; "{"a" * 32}"; "{"b" * 64}"; {json.dumps(decisions)})', old).stdout)
        completed["view"]["rounds"].append(frame("F2"))
        smaller = self.reserve(completed, "shrink")
        self.assertEqual(smaller["recovery"]["referee"], completed["recovery"]["referee"])

    def test_design_redesign_retains_the_loop_but_overrule_closes_it(self):
        seed = '''include "design-audit"; da_empty("/fixture"; "main")
          | da_record({verdict:"FAIL",findings:["high: F1"],advisories:[]}; "issue"; "one")
          | da_record({verdict:"FAIL",findings:["high: F1"],advisories:[]}; "issue"; "two")
          | da_recovery_reserve("referee";
              {task_id:("a"*32),source_sha256:("b"*64),deadline:4102444800})'''
        original = json.loads(model(seed, None).stdout)
        for choice in ("Redesign", "Overrule"):
            result = json.loads(model(
                f'include "design-audit"; da_decide("{choice}"; "issue"; "two")', original).stdout)
            if choice == "Redesign":
                self.assertEqual(result["recovery_state"], original["recovery_state"])
                self.assertEqual(result["failures"], original["failures"])
                request = json.loads(model(
                    'include "design-audit"; da_request("/fixture"; "issue"; "three"; "history")', result).stdout)
                self.assertEqual(request["prior_findings"], ["high: F1"])
            else:
                self.assertIsNone(result["recovery_state"])
                self.assertEqual(result["verdict"], "OVERRIDDEN")


if __name__ == "__main__":
    unittest.main()
