from __future__ import annotations

import json
import re
import unittest
from pathlib import Path


SKILL_ROOT = Path(__file__).resolve().parents[1]
SKILL = SKILL_ROOT / "SKILL.md"
PROMPT = SKILL_ROOT / "references" / "round-agent-prompt.md"
REVIEWER_ADAPTER = SKILL_ROOT / "references" / "reviewer-receipt-adapter.md"
LEDGER = SKILL_ROOT / "references" / "iteration-ledger.md"
EVALS = SKILL_ROOT / "evals" / "evals.json"


class AdversarialIterationContractTests(unittest.TestCase):
    def test_markdown_links_resolve(self) -> None:
        for source in (SKILL, PROMPT):
            text = source.read_text(encoding="utf-8")
            for target in re.findall(r"\[[^]]+\]\(([^)]+)\)", text):
                if "://" in target or target.startswith("#"):
                    continue
                resolved = (source.parent / target.split("#", 1)[0]).resolve()
                self.assertTrue(resolved.exists(), f"broken link in {source}: {target}")

    def test_eval_schema_is_complete(self) -> None:
        payload = json.loads(EVALS.read_text(encoding="utf-8"))
        self.assertEqual(payload["skill_name"], "adversarial-iteration")
        self.assertEqual(
            [item["id"] for item in payload["evals"]], list(range(1, 16))
        )
        for item in payload["evals"]:
            self.assertIsInstance(item["prompt"], str)
            self.assertTrue(item["prompt"])
            self.assertIsInstance(item["expected_output"], str)
            self.assertTrue(item["expected_output"])
            self.assertIsInstance(item["files"], list)
            self.assertIsInstance(item["expectations"], list)
            self.assertTrue(item["expectations"])

    def test_round_prompt_fails_closed(self) -> None:
        prompt = PROMPT.read_text(encoding="utf-8")
        normalized = " ".join(prompt.split())
        self.assertNotIn("empty or absent, treat that as\n   zero findings", prompt)
        self.assertIn("## Independent reviewer receipt", prompt)
        self.assertIn("INPUT_ERROR", prompt)
        self.assertIn("explicit `ZERO_FINDINGS`", prompt)

    def test_codex_review_output_requires_the_receipt_adapter(self) -> None:
        adapter = REVIEWER_ADAPTER.read_text(encoding="utf-8")
        self.assertIn("`/codex:adversarial-review`", adapter)
        for field in ("verdict", "summary", "findings", "next_steps"):
            self.assertIn(f"`{field}`", adapter)
        self.assertIn("Never accept its rendered output directly", adapter)
        self.assertIn("`--wait --json`", adapter)
        self.assertIn("`.result`", adapter)
        self.assertIn("`parseError`", adapter)
        self.assertIn("review_invocation_generation", adapter)
        self.assertNotIn("ledger_generation", adapter)
        self.assertIn("failure_class_registry", adapter)
        self.assertIn("`[NEW_CLASS]`", adapter)
        self.assertIn("`[NEW]`", adapter)
        self.assertIn("dispositions", adapter)
        self.assertIn("REVIEW_FINDING_V1", adapter)
        self.assertIn("REVIEW_EVIDENCE_V1", adapter)
        self.assertIn("ADJACENT_PROPOSAL_V1", adapter)
        self.assertIn("introduced_by", adapter)
        self.assertIn("materiality=material", adapter)
        self.assertIn("redacted opaque", adapter)
        self.assertIn("must remain `unread`", adapter)
        self.assertIn(
            "Do not invoke `/codex:adversarial-review` when any review item is opaque",
            adapter,
        )
        self.assertIn(
            "approve` + empty `findings` + empty `next_steps` + empty `remaining_risk` + complete coverage",
            adapter,
        )
        self.assertIn("`ZERO_FINDINGS`", adapter)
        self.assertIn("remaining_risk", adapter)
        self.assertIn("no other summary lines", " ".join(adapter.split()))

    def test_protocol_states_and_risk_first_handoff_are_pinned(self) -> None:
        text = "\n".join(
            (
                SKILL.read_text(encoding="utf-8"),
                PROMPT.read_text(encoding="utf-8"),
                LEDGER.read_text(encoding="utf-8"),
            )
        )
        for state in (
            "INPUT_ERROR",
            "FINDINGS",
            "BLOCKED",
            "ZERO_FINDINGS",
            "DIVERGED",
            "COMPLETE",
        ):
            self.assertIn(state, text)

        handoff = PROMPT.read_text(encoding="utf-8").split(
            "### Round [N] handoff", maxsplit=1
        )[1]
        self.assertLess(handoff.index("Status"), handoff.index("Remaining risk"))
        self.assertLess(
            handoff.index("Remaining risk"), handoff.index("Input review coverage")
        )
        self.assertLess(handoff.index("Input review coverage"), handoff.index("Findings"))
        self.assertIn("CANDIDATE | INPUT_ERROR", handoff)
        self.assertNotIn("- Status: FINDINGS", handoff)
        self.assertNotIn("- Status: BLOCKED", handoff)
        self.assertNotIn("- Status: DIVERGED", handoff)

    def test_fixer_cannot_own_orchestrator_evidence(self) -> None:
        prompt = PROMPT.read_text(encoding="utf-8")
        normalized = " ".join(prompt.split())
        self.assertIn("Only the orchestrator updates the ledger", normalized)
        self.assertIn("Do not paste prior review receipts", normalized)
        self.assertIn("verification candidate", prompt.lower())
        self.assertIn("apply only that reproducer patch", normalized)
        self.assertIn("After the ten-line risk-first summary", prompt)
        self.assertIn("recurs after its installed preflight", prompt)
        self.assertIn("Never execute fixer-supplied shell text", prompt)
        self.assertIn("argv:", prompt)
        self.assertIn(
            "orchestrator validates/applies the candidate, appends a `fixed_snapshots` entry",
            normalized,
        )
        self.assertIn("fix_attempt_id", prompt)
        self.assertIn("explicitly authorized local-only fixer", prompt)
        self.assertIn("proposed_touched_items", prompt)
        self.assertIn("proposed_adjacent_contracts", prompt)
        self.assertIn("artifact_local_id", prompt)
        self.assertIn("full candidate/handoff", LEDGER.read_text(encoding="utf-8"))
        self.assertIn("before authoritative CAS", LEDGER.read_text(encoding="utf-8"))

    def test_new_preflight_handoff_is_provisional_and_mapped(self) -> None:
        prompt = PROMPT.read_text(encoding="utf-8")
        ledger = LEDGER.read_text(encoding="utf-8")
        for text in (prompt, ledger):
            self.assertIn("proposed_preflights", text)
            self.assertIn("preflight_local_id", text)
            self.assertIn("check_artifact_digest", text)
        self.assertIn("allocate", ledger)
        self.assertIn("rewrite", ledger)
        self.assertIn("at least two recorded occurrences", prompt)
        self.assertIn("at least two recorded occurrences", ledger)

    def test_reviewer_findings_bind_identity_and_public_location(self) -> None:
        adapter = REVIEWER_ADAPTER.read_text(encoding="utf-8")
        for field in (
            "finding_invariant",
            "detection_review_item_id",
            "detection_review_item_digest",
            "detection_evidence_ref",
            "public_location_map",
        ):
            self.assertIn(field, adapter)
        self.assertIn("line_start", adapter)
        self.assertIn("line_end", adapter)
        self.assertIn("exact canonical finding invariant", adapter)

    def test_change_objective_and_instructions_bind_both_roles(self) -> None:
        skill = SKILL.read_text(encoding="utf-8")
        prompt = PROMPT.read_text(encoding="utf-8")
        adapter = REVIEWER_ADAPTER.read_text(encoding="utf-8")
        ledger = LEDGER.read_text(encoding="utf-8")
        for text in (skill, prompt, adapter, ledger):
            self.assertIn("change_objective_digest", text)
            self.assertIn("applicable_instructions_digest", text)

    def test_mutant_potency_is_independently_adjudicated(self) -> None:
        skill = SKILL.read_text(encoding="utf-8")
        prompt = PROMPT.read_text(encoding="utf-8")
        ledger = LEDGER.read_text(encoding="utf-8")
        self.assertIn("independent potency", skill)
        self.assertIn("MUTANT_POTENCY_V1", prompt)
        self.assertIn("mutant_potency_receipts", ledger)
        self.assertIn("potency_receipt_id", ledger)
        self.assertIn("candidate_snapshot_digest", prompt)
        self.assertIn("before authoritative apply", ledger)
        self.assertIn("proposed_mutants", prompt)
        self.assertIn("mutant_local_id", prompt)
        self.assertIn("next_mutant_sequence", ledger)
        self.assertIn("expected_kill_signal_digest", prompt)
        self.assertIn("expected_kill_signal_digest", ledger)

    def test_reflect_keeps_per_finding_classes(self) -> None:
        skill = SKILL.read_text(encoding="utf-8")
        prompt = PROMPT.read_text(encoding="utf-8")
        self.assertIn("per-finding failure class", skill)
        self.assertIn("per-finding failure class", prompt)
        self.assertIn("optional cross-finding pattern", prompt)

    def test_every_class_mapping_is_independently_adjudicated(self) -> None:
        adapter = REVIEWER_ADAPTER.read_text(encoding="utf-8")
        self.assertIn("pause every finding's normalization", adapter)
        self.assertIn("reviewer-claimed slug", adapter)

    def test_public_reviewer_is_os_confined(self) -> None:
        adapter = REVIEWER_ADAPTER.read_text(encoding="utf-8")
        self.assertIn("OS-enforced data-read allowlist", adapter)
        self.assertIn("deny direct network", adapter)
        self.assertIn("disabled system/global Git config", adapter)
        self.assertIn("deterministic dummy author/committer metadata", adapter)

    def test_entry_kind_enum_is_canonical(self) -> None:
        ledger = LEDGER.read_text(encoding="utf-8")
        self.assertNotIn("blob/symlink/submodule", ledger)
        self.assertIn("blob/symlink/gitlink", ledger)

    def test_accumulated_evidence_accepts_stable_entry_references(self) -> None:
        prompt = PROMPT.read_text(encoding="utf-8")
        ledger = LEDGER.read_text(encoding="utf-8")
        self.assertIn("surface-entry ID or artifact_local_id", prompt)
        self.assertIn("resolve every existing stable or candidate-local entry reference", ledger)

    def test_provenance_covers_lifecycle_and_mode_transitions(self) -> None:
        adapter = REVIEWER_ADAPTER.read_text(encoding="utf-8")
        ledger = LEDGER.read_text(encoding="utf-8")
        for text in (adapter, ledger):
            self.assertIn("lifecycle/mode/type/path/patch", text)

    def test_verification_output_uses_no_log_projection(self) -> None:
        ledger = LEDGER.read_text(encoding="utf-8")
        for field in (
            "output_artifact",
            "output_digest",
            "output_sensitivity",
            "decisive_signal_digest",
        ):
            self.assertIn(field, ledger)
        self.assertIn("same no-log", ledger)

    def test_every_agent_role_has_bounded_liveness(self) -> None:
        prompt = PROMPT.read_text(encoding="utf-8")
        adapter = REVIEWER_ADAPTER.read_text(encoding="utf-8")
        ledger = LEDGER.read_text(encoding="utf-8")
        self.assertIn("role_timeout_policies", ledger)
        self.assertIn("role_timeout_rejections", ledger)
        self.assertIn("pending_adjudication_requests", ledger)
        self.assertIn("consumed_adjudication_request_ids", ledger)
        self.assertIn("adjudication_request_rejections", ledger)
        self.assertIn("reason_code: crash | timeout | output_limit | potency |", ledger)
        self.assertIn("parent_generation_chain_digest", ledger)
        self.assertIn("parent-bound subordinate adjudication transitions", ledger)
        self.assertNotIn(
            "No other write may occur before that request is accepted or rejected.",
            ledger,
        )
        self.assertIn("potency_request_id", prompt)
        self.assertIn("class_adjudication_request_id", adapter)
        self.assertIn("host-owned finite deadline", adapter)

    def test_verification_exec_is_os_sandboxed(self) -> None:
        ledger = LEDGER.read_text(encoding="utf-8")
        self.assertIn("OS sandbox", ledger)
        self.assertIn("default-deny network", ledger)
        self.assertIn("scrubbed environment", ledger)
        self.assertIn("sandbox_attestation_digest", ledger)
        self.assertIn("authoritative_recapture_digest", ledger)

    def test_verification_result_mapping_is_mechanical(self) -> None:
        prompt = PROMPT.read_text(encoding="utf-8")
        ledger = LEDGER.read_text(encoding="utf-8")
        for field in (
            "runner_contract_digest",
            "expected_termination",
            "expected_exit_code",
            "signal_predicate_digest",
        ):
            self.assertIn(field, prompt)
            self.assertIn(field, ledger)
        self.assertIn("Phase-result mapping", ledger)

    def test_ledger_binds_scope_lineage_and_verification(self) -> None:
        ledger = LEDGER.read_text(encoding="utf-8")
        required_fields = (
            "base_revision",
            "surface_fingerprint",
            "reviewed_full",
            "reviewed_partial",
            "unread",
            "introduced_by",
            "detected_in",
            "representative_mutant",
            "expected_failure",
            "verification_receipt",
            "loop_start_snapshot",
            "pre_round_snapshot",
            "fixed_snapshot",
            "snapshot_digest",
            "snapshot_artifact",
            "surface_entry_id",
            "lifecycle",
            "prior_path",
            "reproducer_id",
            "reproducer_digest",
            "reproducer_artifact",
            "mutant_digest",
            "mutant_artifact",
            "expected_touched_entries",
            "compatibility_adapter",
            "adapter_digest",
            "sensitivity",
            "redacted_token",
            "severity",
            "materiality",
            "origins",
            "max_projection_bytes",
            "max_projection_entries",
            "projection_digest",
            "review_target_digest",
            "review_request_id",
            "review_invocation_generation",
            "reviewer_receipts",
            "reviewed_after_attempt",
            "fix_attempt_id",
            "fix_dispatch_id",
            "fix_dispatch_rejections",
            "retry_of_dispatch_id",
            "attempt_deltas",
            "context_discovery_receipts",
            "context_discovery_digest",
            "divergence_evaluations",
            "evaluated_generation",
            "blocked_receipts",
            "permitted_existing_entry_ids",
            "permitted_new_normalized_paths",
            "consumed_review_request_ids",
            "review_request_rejections",
            "review_item_id",
            "review_item_digest",
            "adjacent_contract_id",
            "check_id",
            "old_kind_mode",
            "new_kind_mode",
            "review_artifact",
            "ledger_digest",
            "max_files",
            "max_bytes",
            "phase",
            "expected_result",
            "timeout_policy_id",
            "timeout_ms",
            "process_group_cleanup",
        )
        for field in required_fields:
            self.assertIn(field, ledger)
        self.assertIn("isolated disposable copy", ledger)
        self.assertIn("isolated candidate copy", ledger)
        self.assertIn("atomic replacement", ledger)
        self.assertIn("## Guarded finding transitions", ledger)
        self.assertIn("Absence is not closure", ledger)
        self.assertIn("resolved immutable full commit object ID", ledger)
        self.assertNotIn("\n    origin:", ledger)
        self.assertIn("Never truncate", ledger)
        self.assertIn("with `ledger_digest` omitted", ledger)
        self.assertIn("append-only", ledger)
        self.assertIn("`lstat`", ledger)
        self.assertIn("`readlink`", ledger)
        self.assertIn("never dereference", ledger.lower())
        self.assertIn("gitlink", ledger)
        self.assertIn("never traverse", ledger.lower())
        self.assertIn("no-log", ledger.lower())
        self.assertIn("`st_nlink`", ledger)


if __name__ == "__main__":
    unittest.main()
