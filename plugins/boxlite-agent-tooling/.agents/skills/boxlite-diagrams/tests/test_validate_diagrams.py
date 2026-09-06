from __future__ import annotations

import copy
import json
import os
import subprocess
import sys
import tempfile
import threading
import unittest
import unittest.mock
from pathlib import Path

SKILL_ROOT = Path(__file__).resolve().parents[1]
SCRIPT = SKILL_ROOT / "scripts" / "validate_diagrams.py"
sys.path.insert(0, str(SKILL_ROOT / "scripts"))

from validate_diagrams import _write_report
from validator.mermaid import LAPTOP_VIEWPORT, _svg_size
from validator.changes import _parse_diff

SCOPE_COMPUTE_STYLES = "fill:#dcfce7,stroke:#16a34a,color:#1f2933"


class DiagramValidatorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self._run("git", "init", "-q")
        self._run("git", "config", "user.email", "test@example.com")
        self._run("git", "config", "user.name", "Test")
        source = "def start():\n    return load()\n\ndef load():\n    return 'base'\n"
        (self.repo / "app.py").write_text(source, encoding="utf-8")
        self._run("git", "add", "app.py")
        self._run("git", "commit", "-q", "-m", "base")
        self.base = self._run("git", "rev-parse", "HEAD").stdout.strip()
        source = (
            "def start():\n    validate()\n    return load()\n\ndef validate():\n"
            "    return True\n\ndef load():\n    return 'head'\n"
        )
        (self.repo / "app.py").write_text(source, encoding="utf-8")
        self._run("git", "add", "app.py")
        self._run("git", "commit", "-q", "-m", "head")
        self.head = self._run("git", "rev-parse", "HEAD").stdout.strip()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self._write_fake_mmdc()
        self._write_fake_gh()
        self.env = os.environ.copy()
        self.env["PATH"] = f"{self.bin}:{self.env['PATH']}"
        self.env["BOXLITE_DIAGRAM_MMDC"] = str(self.bin / "fake-mmdc")

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_valid_overview(self) -> None:
        result, report = self.validate(*overview_fixture(self.head))
        self.assertEqual(result.returncode, 0, result.stderr + json.dumps(report, indent=2))
        self.assertTrue(report["valid"])

    def test_valid_architecture_only_overview(self) -> None:
        document, manifest = architecture_only_fixture(self.head)
        result, report = self.validate(document, manifest)
        self.assertEqual(result.returncode, 0, result.stderr + json.dumps(report, indent=2))
        self.assertTrue(report["valid"])
        artifacts = [Path(value).suffix for value in report["artifacts"]]
        self.assertIn(".svg", artifacts)
        self.assertIn(".png", artifacts)

    def test_valid_source_grounded_boundary_containment(self) -> None:
        result, report = self.validate(*contained_architecture_fixture(self.head))
        self.assertEqual(result.returncode, 0, result.stderr + json.dumps(report, indent=2))
        consistency = next(check for check in report["checks"] if check["name"] == "consistency.cross_view")
        self.assertIn("boundaries", consistency["message"])

    def test_wrong_immediate_boundary_is_rejected(self) -> None:
        document, manifest = contained_architecture_fixture(self.head)
        document = document.replace(
            '    start["start"]\n    load["load"]\n  end',
            '    start["start"]\n  end\n  load["load"]',
            1,
        )
        result, report = self.validate(document, manifest)
        self.assertEqual(result.returncode, 1)
        self.assert_check_failed(report, "consistency.cross_view")

    def test_undeclared_mermaid_boundary_is_rejected(self) -> None:
        document, manifest = contained_architecture_fixture(self.head)
        document = document.replace(
            '  subgraph inner["Inner"]',
            '  subgraph extra["Extra"]\n    subgraph inner["Inner"]',
            1,
        ).replace('  end\nend', '    end\n  end\nend', 1)
        result, report = self.validate(document, manifest)
        self.assertEqual(result.returncode, 1)
        self.assert_check_failed(report, "consistency.cross_view")

    def test_member_cannot_have_two_immediate_boundaries(self) -> None:
        document, manifest = contained_architecture_fixture(self.head)
        manifest["boundaries"][0]["members"].append({"target": "node:start", "states": ["current"]})
        result, report = self.validate(document, manifest)
        self.assertEqual(result.returncode, 1)
        self.assert_check_failed(report, "manifest.shape")

    def test_boundary_cycle_is_rejected(self) -> None:
        document, manifest = contained_architecture_fixture(self.head)
        manifest["boundaries"][1]["members"].append(
            {"target": "boundary:outer", "states": ["current"]}
        )
        result, report = self.validate(document, manifest)
        self.assertEqual(result.returncode, 1)
        self.assert_check_failed(report, "manifest.shape")

    def test_unselected_view_is_rejected(self) -> None:
        document, manifest = architecture_only_fixture(self.head)
        document += "\n## Sequence\n\n### Current\n\n```mermaid\nsequenceDiagram\n```\n"
        result, report = self.validate(document, manifest)
        self.assertEqual(result.returncode, 1)
        self.assert_check_failed(report, "document.structure")

    def test_item_view_outside_selected_views_is_rejected(self) -> None:
        document, manifest = architecture_only_fixture(self.head)
        manifest["nodes"][0]["views"] = ["sequence"]
        result, report = self.validate(document, manifest)
        self.assertEqual(result.returncode, 1)
        self.assert_check_failed(report, "manifest.shape")

    def test_valid_call_graph_only_without_mermaid_tool(self) -> None:
        document, manifest = call_graph_only_fixture(self.head)
        environment = self.env | {"PATH": f"{self.bin}:/usr/bin:/bin", "BOXLITE_DIAGRAM_MMDC": ""}
        result, report = self.validate(document, manifest, environment=environment)
        self.assertEqual(result.returncode, 0, result.stderr + json.dumps(report, indent=2))
        render = next(check for check in report["checks"] if check["name"] == "mermaid.render")
        self.assertEqual(render["message"], "no Mermaid view was selected")

    def test_valid_unimplemented_issue(self) -> None:
        document, manifest = issue_fixture(self.head)
        result, report = self.validate(document, manifest)
        self.assertEqual(result.returncode, 0, json.dumps(report, indent=2))

    def test_valid_feature_pr(self) -> None:
        document, manifest = feature_pr_fixture(self.base, self.head)
        result, report = self.validate(document, manifest)
        self.assertEqual(result.returncode, 0, json.dumps(report, indent=2))

    def test_valid_bug_fix_pr(self) -> None:
        document, manifest = bug_pr_fixture(self.base, self.head)
        result, report = self.validate(document, manifest)
        self.assertEqual(result.returncode, 0, json.dumps(report, indent=2))

    def test_missing_call_graph_state_is_rejected(self) -> None:
        document, manifest = feature_pr_fixture(self.base, self.head)
        document = document.replace("### After\n\n```text\n  start", "### After\n\n  start", 1)
        result, report = self.validate(document, manifest)
        self.assertEqual(result.returncode, 1)
        self.assert_check_failed(report, "document.structure")

    def test_malformed_call_graph_hop_is_rejected(self) -> None:
        document, manifest = overview_fixture(self.head)
        document = document.replace("start (Module ·", "start Module ·")
        result, report = self.validate(document, manifest)
        self.assertEqual(result.returncode, 1)
        self.assert_check_failed(report, "call_graph.structure")

    def test_fabricated_symbol_is_rejected(self) -> None:
        document, manifest = overview_fixture(self.head)
        manifest["nodes"][0]["evidence"][0]["symbol"] = "fabricated"
        result, report = self.validate(document, manifest)
        self.assertEqual(result.returncode, 1)
        self.assert_check_failed(report, "source.evidence")

    def test_unknown_manifest_field_is_rejected(self) -> None:
        document, manifest = overview_fixture(self.head)
        manifest["nodes"][0]["untrusted"] = "ignored"
        result, report = self.validate(document, manifest)
        self.assertEqual(result.returncode, 1)
        self.assert_check_failed(report, "manifest.shape")

    def test_array_manifest_writes_machine_readable_report(self) -> None:
        document, _manifest = overview_fixture(self.head)
        result, report = self.validate(document, [])
        self.assertEqual(result.returncode, 1)
        self.assert_check_failed(report, "manifest.shape")

    def test_malformed_annotation_target_writes_machine_readable_report(self) -> None:
        document, manifest = issue_fixture(self.head)
        manifest["annotations"][0]["target"] = "edge"
        result, report = self.validate(document, manifest)
        self.assertEqual(result.returncode, 1)
        self.assert_check_failed(report, "manifest.shape")

    def test_context_source_values_follow_schema_types(self) -> None:
        document, manifest = overview_fixture(self.head)
        manifest["context"]["sources"]["repository"] = 1
        result, report = self.validate(document, manifest)
        self.assertEqual(result.returncode, 1)
        self.assert_check_failed(report, "manifest.shape")

    def test_option_like_revision_is_rejected_at_manifest_boundary(self) -> None:
        document, manifest = overview_fixture(self.head)
        manifest["states"][0]["revision"] = "--help"
        for item in manifest["nodes"] + manifest["edges"]:
            for evidence in item["evidence"]:
                evidence["revision"] = "--help"
        result, report = self.validate(document, manifest)
        self.assertEqual(result.returncode, 1)
        self.assert_check_failed(report, "manifest.shape")

    def test_source_revision_must_match_its_state(self) -> None:
        document, manifest = feature_pr_fixture(self.base, self.head)
        manifest["nodes"][0]["evidence"][0]["revision"] = self.head
        result, report = self.validate(document, manifest)
        self.assertEqual(result.returncode, 1)
        self.assert_check_failed(report, "source.evidence")

    def test_stale_line_is_rejected(self) -> None:
        document, manifest = overview_fixture(self.head)
        evidence = manifest["nodes"][0]["evidence"][0]
        evidence["line_start"] = 99
        evidence["line_end"] = 99
        result, report = self.validate(document, manifest)
        self.assertEqual(result.returncode, 1)
        self.assert_check_failed(report, "source.evidence")

    def test_real_symbols_with_unsupported_edge_are_rejected(self) -> None:
        document, manifest = overview_fixture(self.head)
        edge = manifest["edges"][0]
        edge["evidence"][0]["line_start"] = 8
        edge["evidence"][0]["line_end"] = 9
        edge["evidence"][0]["symbol"] = "load"
        edge["evidence"][0]["tokens"] = ["def load"]
        result, report = self.validate(document, manifest)
        self.assertEqual(result.returncode, 1)
        self.assert_check_failed(report, "source.evidence")

    def test_bug_in_after_is_rejected(self) -> None:
        document, manifest = bug_pr_fixture(self.base, self.head)
        bug = next(value for value in manifest["annotations"] if value["kind"] == "BUG")
        bug["state"] = "after"
        result, report = self.validate(document, manifest)
        self.assertEqual(result.returncode, 1)
        self.assert_check_failed(report, "changes.alignment")

    def test_bug_marker_in_prose_is_rejected(self) -> None:
        document, manifest = bug_pr_fixture(self.base, self.head)
        document = document.replace(" — load result ← BUG: stale result", " — load result\nBUG: stale result")
        result, report = self.validate(document, manifest)
        self.assertEqual(result.returncode, 1)
        self.assert_check_failed(report, "call_graph.structure")

    def test_incorrect_diff_annotation_is_rejected(self) -> None:
        document, manifest = feature_pr_fixture(self.base, self.head)
        added = next(value for value in manifest["annotations"] if value["kind"] == "ADDED")
        added["target"] = "node:load"
        load = next(value for value in manifest["nodes"] if value["id"] == "load")
        after = next(value for value in load["evidence"] if value["state"] == "after")
        after["line_end"] = 8
        after["tokens"] = ["def load"]
        result, report = self.validate(document, manifest)
        self.assertEqual(result.returncode, 1)
        self.assert_check_failed(report, "changes.alignment")

    def test_cross_view_disagreement_is_rejected(self) -> None:
        document, manifest = overview_fixture(self.head)
        document = document.replace("%% edge:start_load", "%% edge:other")
        result, report = self.validate(document, manifest)
        self.assertEqual(result.returncode, 1)
        self.assert_check_failed(report, "consistency.cross_view")

    def test_annotation_missing_from_mermaid_target_is_rejected(self) -> None:
        document, manifest = issue_fixture(self.head)
        document = document.replace("load PROPOSED: validation behavior", "load", 1)
        result, report = self.validate(document, manifest)
        self.assertEqual(result.returncode, 1)
        self.assert_check_failed(report, "consistency.cross_view")

    def test_state_order_mismatch_is_rejected(self) -> None:
        document, manifest = feature_pr_fixture(self.base, self.head)
        before_start = document.index("### Before")
        after_start = document.index("### After", before_start)
        section_end = document.index("## Sequence")
        before_block = document[before_start:after_start]
        after_block = document[after_start:section_end]
        document = document[:before_start] + after_block + before_block + document[section_end:]
        result, report = self.validate(document, manifest)
        self.assertEqual(result.returncode, 1)
        self.assert_check_failed(report, "document.structure")

    def test_pr_revision_mismatch_is_rejected(self) -> None:
        document, manifest = feature_pr_fixture(self.base, self.head)
        manifest["context"]["sources"]["head_revision"] = self.base
        result, report = self.validate(document, manifest)
        self.assertEqual(result.returncode, 1)
        self.assert_check_failed(report, "source.evidence")

    def test_broken_mermaid_is_rejected(self) -> None:
        document, manifest = overview_fixture(self.head)
        document = document.replace("flowchart LR", "flowchart LR\n  BROKEN")
        result, report = self.validate(document, manifest)
        self.assertEqual(result.returncode, 1)
        self.assert_check_failed(report, "mermaid.render")

    def test_unsafe_mermaid_is_rejected(self) -> None:
        document, manifest = overview_fixture(self.head)
        document = document.replace("flowchart LR", "flowchart LR\n  click start href \"https://example.com\"")
        result, report = self.validate(document, manifest)
        self.assertEqual(result.returncode, 1)
        self.assert_check_failed(report, "mermaid.structure_security")

    def test_non_palette_classdef_is_rejected(self) -> None:
        document, manifest = architecture_only_fixture(self.head)
        document = document.replace("flowchart LR", "flowchart LR\n  classDef fixed fill:#fff,color:#000")
        result, report = self.validate(document, manifest)
        self.assertEqual(result.returncode, 1)
        self.assert_check_failed(report, "mermaid.structure_security")

    def test_altered_palette_classdef_is_rejected(self) -> None:
        document, manifest = architecture_only_fixture(self.head)
        document = document.replace(
            "flowchart LR", "flowchart LR\n  classDef scope_state fill:#ffffff,stroke:#000000,color:#000000"
        )
        result, report = self.validate(document, manifest)
        self.assertEqual(result.returncode, 1)
        self.assert_check_failed(report, "mermaid.structure_security")

    def test_style_directive_is_rejected(self) -> None:
        document, manifest = architecture_only_fixture(self.head)
        document = document.replace("flowchart LR", "flowchart LR\n  style start fill:#fff")
        result, report = self.validate(document, manifest)
        self.assertEqual(result.returncode, 1)
        self.assert_check_failed(report, "mermaid.structure_security")

    def test_scope_class_on_node_is_rejected(self) -> None:
        document, manifest = contained_architecture_fixture(self.head)
        document = document.replace(
            "flowchart TB", f"flowchart TB\nclassDef scope_compute {SCOPE_COMPUTE_STYLES}", 1
        )
        document = document.replace(
            'start start_load@-->|"load"| load',
            'start start_load@-->|"load"| load\nclass start scope_compute',
            1,
        )
        result, report = self.validate(document, manifest)
        self.assertEqual(result.returncode, 1)
        self.assert_check_failed(report, "mermaid.structure_security")

    def test_classdef_in_sequence_is_rejected(self) -> None:
        document, manifest = overview_fixture(self.head)
        document = document.replace(
            "sequenceDiagram", f"sequenceDiagram\n  classDef scope_compute {SCOPE_COMPUTE_STYLES}", 1
        )
        result, report = self.validate(document, manifest)
        self.assertEqual(result.returncode, 1)
        self.assert_check_failed(report, "mermaid.structure_security")

    def test_valid_scope_zone_palette(self) -> None:
        result, report = self.validate(*scoped_zone_fixture(self.head))
        self.assertEqual(result.returncode, 0, result.stderr + json.dumps(report, indent=2))
        self.assertTrue(report["valid"])

    def test_zone_scope_mismatch_is_rejected(self) -> None:
        document, manifest = scoped_zone_fixture(self.head)
        manifest["boundaries"][1]["scope"] = "state"
        result, report = self.validate(document, manifest)
        self.assertEqual(result.returncode, 1)
        self.assert_check_failed(report, "consistency.cross_view")

    def test_declared_scope_without_drawn_class_is_rejected(self) -> None:
        document, manifest = contained_architecture_fixture(self.head)
        manifest["boundaries"][1]["scope"] = "compute"
        result, report = self.validate(document, manifest)
        self.assertEqual(result.returncode, 1)
        self.assert_check_failed(report, "consistency.cross_view")

    def test_drawn_scope_without_declared_scope_is_rejected(self) -> None:
        document, manifest = scoped_zone_fixture(self.head)
        del manifest["boundaries"][1]["scope"]
        result, report = self.validate(document, manifest)
        self.assertEqual(result.returncode, 1)
        self.assert_check_failed(report, "consistency.cross_view")

    def test_invalid_boundary_scope_value_is_rejected(self) -> None:
        document, manifest = contained_architecture_fixture(self.head)
        manifest["boundaries"][1]["scope"] = "banana"
        result, report = self.validate(document, manifest)
        self.assertEqual(result.returncode, 1)
        self.assert_check_failed(report, "manifest.shape")

    def test_malformed_html_comment_is_rejected(self) -> None:
        document, manifest = overview_fixture(self.head)
        document = document.replace('start["start"]', 'start["start<!-- unsafe --!>"]', 1)
        result, report = self.validate(document, manifest)
        self.assertEqual(result.returncode, 1)
        self.assert_check_failed(report, "mermaid.structure_security")

    def test_mermaid_br_line_break_is_accepted(self) -> None:
        document, manifest = architecture_only_fixture(self.head)
        document = document.replace('start["start"]', 'start["start<br/>entry"]')
        result, report = self.validate(document, manifest)
        self.assertEqual(result.returncode, 0, json.dumps(report, indent=2))

    def test_sequence_message_without_source_fields_is_rejected(self) -> None:
        document, manifest = overview_fixture(self.head)
        document = document.replace(sequence_message("load", "load", 8, 9), "load", 1)
        result, report = self.validate(document, manifest)
        self.assertEqual(result.returncode, 1)
        self.assert_check_failed(report, "sequence.source_labels")

    def test_sequence_message_preserves_complete_nested_namespace(self) -> None:
        document, manifest = overview_fixture(self.head)
        load = next(node for node in manifest["nodes"] if node["id"] == "load")
        load["evidence"][0]["symbol"] = "package.module.Loader.load"
        document = document.replace(
            sequence_message("load", "load", 8, 9),
            sequence_message(
                "load", "load", 8, 9, namespace="package.module", class_name="Loader"
            ),
            1,
        )
        result, report = self.validate(document, manifest)
        self.assertEqual(result.returncode, 0, json.dumps(report, indent=2))

    def test_sequence_message_rejects_collapsed_nested_namespace(self) -> None:
        document, manifest = overview_fixture(self.head)
        load = next(node for node in manifest["nodes"] if node["id"] == "load")
        load["evidence"][0]["symbol"] = "package.module.Loader.load"
        document = document.replace(
            sequence_message("load", "load", 8, 9),
            sequence_message("load", "load", 8, 9, namespace="module", class_name="Loader"),
            1,
        )
        result, report = self.validate(document, manifest)
        self.assertEqual(result.returncode, 1)
        self.assert_check_failed(report, "sequence.source_labels")

    def test_mermaid_left_arrow_is_not_treated_as_html(self) -> None:
        document, manifest = overview_fixture(self.head)
        document = document.replace("start_load@-->", "start_load@<-->", 1)
        result, report = self.validate(document, manifest)
        self.assertEqual(result.returncode, 0, json.dumps(report, indent=2))

    def test_closing_fence_with_trailing_whitespace_is_accepted(self) -> None:
        document, manifest = overview_fixture(self.head)
        document = document.replace("```\n\n## Sequence", "``` \n\n## Sequence", 1)
        result, report = self.validate(document, manifest)
        self.assertEqual(result.returncode, 0, json.dumps(report, indent=2))

    def test_architecture_ids_starting_with_end_are_parsed(self) -> None:
        document, manifest = overview_fixture(self.head)
        document = document.replace('start["start"]', 'endpoint["start"]')
        document = document.replace('load["load"]', 'end_state["load"]')
        document = document.replace('start start_load@-->|"load"| load', 'endpoint endpoint_end_state@-->|"load"| end_state')
        document = document.replace('participant start as start', 'participant endpoint as start')
        document = document.replace('participant load as load', 'participant end_state as load')
        document = document.replace('%% edge:start_load', '%% edge:endpoint_end_state')
        document = document.replace('start->>load: load', 'endpoint->>end_state: load')
        manifest["nodes"][0]["id"] = "endpoint"
        manifest["nodes"][1]["id"] = "end_state"
        manifest["edges"][0].update({"id": "endpoint_end_state", "from": "endpoint", "to": "end_state"})
        result, report = self.validate(document, manifest)
        self.assertEqual(result.returncode, 0, json.dumps(report, indent=2))

    def test_direct_call_in_python_comment_is_not_evidence(self) -> None:
        self._assert_non_code_call_is_rejected("# load()", "comments.py")

    def test_direct_call_in_rust_string_is_not_evidence(self) -> None:
        self._assert_non_code_call_is_rejected('let note = "load()";', "comments.rs")

    def test_mermaid_timeout_returns_tool_error(self) -> None:
        document, manifest = overview_fixture(self.head)
        sleeper = self.bin / "slow-mmdc"
        sleeper.write_text("#!/bin/sh\nsleep 1\n", encoding="utf-8")
        sleeper.chmod(0o755)
        environment = self.env | {
            "BOXLITE_DIAGRAM_MMDC": str(sleeper),
            "BOXLITE_DIAGRAM_COMMAND_TIMEOUT": "0.05",
        }
        result, report = self.validate(document, manifest, environment=environment)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(report["exit_code"], 2)

    def test_gh_timeout_returns_tool_error(self) -> None:
        document, manifest = issue_fixture(self.head)
        (self.bin / "gh").write_text("#!/bin/sh\nsleep 1\n", encoding="utf-8")
        environment = self.env | {"BOXLITE_DIAGRAM_COMMAND_TIMEOUT": "0.05"}
        result, report = self.validate(document, manifest, environment=environment)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(report["exit_code"], 2)

    def test_deleted_file_hunks_use_the_deleted_path(self) -> None:
        diff = _parse_diff(
            "diff --git a/first.py b/first.py\n--- a/first.py\n+++ b/first.py\n@@ -1 +1 @@\n"
            "diff --git a/deleted.py b/deleted.py\n--- a/deleted.py\n+++ /dev/null\n@@ -7,2 +0,0 @@\n"
        )
        self.assertEqual(diff["deleted.py"]["before"], [(7, 8)])
        self.assertNotIn((7, 8), diff["first.py"]["before"])

    def test_report_writes_use_unique_temporary_files(self) -> None:
        report_path = self.root / "concurrent" / "validation.json"
        barrier = threading.Barrier(2)
        failures: list[Exception] = []
        original_write_text = Path.write_text

        def synchronized_write(path: Path, *args: object, **kwargs: object) -> int:
            written = original_write_text(path, *args, **kwargs)
            if path.parent == report_path.parent and path != report_path:
                barrier.wait(timeout=2)
            return written

        def write(value: int) -> None:
            try:
                _write_report(report_path, {"value": value})
            except Exception as error:
                failures.append(error)

        with unittest.mock.patch.object(Path, "write_text", synchronized_write):
            threads = [threading.Thread(target=write, args=(value,)) for value in (1, 2)]
            for thread in threads:
                thread.start()
            for thread in threads:
                thread.join(timeout=3)
        self.assertFalse(failures)
        self.assertIn(json.loads(report_path.read_text(encoding="utf-8"))["value"], {1, 2})

    def test_bug_marker_contract_requires_left_arrow(self) -> None:
        contract = (SKILL_ROOT / "references" / "output-contract.md").read_text(encoding="utf-8")
        skill = (SKILL_ROOT / "SKILL.md").read_text(encoding="utf-8")
        evals = (SKILL_ROOT / "evals" / "evals.json").read_text(encoding="utf-8")
        for content in (contract, skill, evals):
            self.assertIn("← BUG:", content)

    def test_cloud_architecture_contract_requires_containment_zones_and_palette(self) -> None:
        skill = (SKILL_ROOT / "SKILL.md").read_text(encoding="utf-8")
        composition = (SKILL_ROOT / "references" / "architecture-composition.md").read_text(encoding="utf-8")
        contract = (SKILL_ROOT / "references" / "output-contract.md").read_text(encoding="utf-8")
        evals = (SKILL_ROOT / "evals" / "evals.json").read_text(encoding="utf-8")
        # The containment chain, zones, and palette are single-sourced in the composition
        # reference rather than repeated in every file, so SKILL.md must route every
        # architecture request to it for the invariants to reach the agent.
        for needle in ("Runner fleet", "EC2", "embedded BoxLite", "light/dark", "scope_"):
            self.assertIn(needle, composition)
            self.assertIn(needle, evals)
        self.assertIn("architecture-composition.md", skill)
        self.assertIn("architecture, deployment, topology, overview", skill)
        for needle in ("light/dark", "scope_"):
            self.assertIn(needle, contract)

    def test_topic_tree_contract_is_documented(self) -> None:
        skill = (SKILL_ROOT / "SKILL.md").read_text(encoding="utf-8")
        composition = (SKILL_ROOT / "references" / "architecture-composition.md").read_text(encoding="utf-8")
        contract = (SKILL_ROOT / "references" / "output-contract.md").read_text(encoding="utf-8")
        evals = (SKILL_ROOT / "evals" / "evals.json").read_text(encoding="utf-8")
        for content in (skill, contract, evals):
            self.assertIn("topics", content)
            self.assertIn(str(LAPTOP_VIEWPORT[0]), content)
        self.assertIn("<details>", contract)
        self.assertIn("<summary>", contract)
        self.assertIn("parent", contract)
        self.assertIn(str(LAPTOP_VIEWPORT[1]), composition)

    def test_proposed_behavior_without_issue_evidence_is_rejected(self) -> None:
        document, manifest = issue_fixture(self.head)
        for item in manifest["nodes"] + manifest["edges"]:
            item["evidence"] = [value for value in item["evidence"] if value["type"] == "source"]
        result, report = self.validate(document, manifest)
        self.assertEqual(result.returncode, 1)
        self.assert_check_failed(report, "source.evidence")

    def test_missing_mermaid_tool_returns_two(self) -> None:
        document, manifest = overview_fixture(self.head)
        environment = self.env | {"PATH": f"{self.bin}:/usr/bin:/bin", "BOXLITE_DIAGRAM_MMDC": ""}
        result, report = self.validate(document, manifest, environment=environment)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(report["exit_code"], 2)

    @unittest.skipUnless(os.environ.get("BOXLITE_DIAGRAM_REAL_RENDER") == "1", "real renderer opt-in")
    def test_real_three_level_topic_render(self) -> None:
        # Proves the depth-3 path end to end on the pinned renderer: three nested
        # topics, three measured diagrams, three distinct artifact sets.
        environment = self.env.copy()
        environment.pop("BOXLITE_DIAGRAM_MMDC", None)
        result, report = self.validate(
            topic_document({"overview": ["start"], "start": ["validate"], "validate": []}),
            topic_manifest(self.head, THREE_LEVEL_TOPICS),
            environment=environment,
        )
        self.assertEqual(result.returncode, 0, result.stderr + json.dumps(report, indent=2))
        topics = next(check for check in report["checks"] if check["name"] == "manifest.topics")
        self.assertIn("3 level(s) deep", topics["message"])
        previews = sorted(Path(value).name for value in report["artifacts"] if value.endswith(".png"))
        self.assertEqual(previews, [
            "architecture-current-overview.png",
            "architecture-current-start.png",
            "architecture-current-validate.png",
        ])
        for topic in ("overview", "start", "validate"):
            viewport = next(
                check for check in report["checks"] if check["name"] == f"{topic}/mermaid.viewport"
            )
            self.assertEqual(viewport["status"], "pass", json.dumps(viewport, indent=2))

    @unittest.skipUnless(os.environ.get("BOXLITE_DIAGRAM_REAL_RENDER") == "1", "real renderer opt-in")
    def test_real_pinned_mermaid_render(self) -> None:
        document, manifest = overview_fixture(self.head)
        environment = self.env.copy()
        environment.pop("BOXLITE_DIAGRAM_MMDC", None)
        result, report = self.validate(document, manifest, environment=environment)
        self.assertEqual(result.returncode, 0, result.stderr + json.dumps(report, indent=2))
        render = next(check for check in report["checks"] if check["name"] == "mermaid.render")
        self.assertIn("@11.16.0", render["message"])

    def test_diagram_larger_than_a_laptop_screen_is_rejected(self) -> None:
        environment = self.env.copy()
        environment["BOXLITE_FAKE_SVG_SIZE"] = "2400 1800"
        result, report = self.validate(*overview_fixture(self.head), environment=environment)
        self.assertEqual(result.returncode, 1)
        self.assert_evidence(report, "mermaid.viewport", "larger than a 1600x900 laptop viewport")

    def test_diagram_within_a_laptop_screen_passes(self) -> None:
        result, report = self.validate(*overview_fixture(self.head))
        self.assertEqual(result.returncode, 0, result.stderr + json.dumps(report, indent=2))
        viewport = next(check for check in report["checks"] if check["name"] == "mermaid.viewport")
        self.assertEqual(viewport["status"], "pass")

    def test_malformed_manifests_always_leave_a_named_report(self) -> None:
        # validate_topics, filter_manifest, and parse_document all read the manifest
        # before validate_manifest does, so every field they touch is type-gated. The
        # cases are generated from (field x bad type) rather than hand-picked, because
        # each earlier gap hid in a path a curated list did not happen to reach.
        for label, manifest in malformed_manifests(self.head):
            with self.subTest(shape=label):
                report = self.run_in_process(TOPIC_DOCUMENT_TEXT, manifest)
                statuses = dict(report)
                failed = {name for name, status in report if status == "fail"}
                self.assertNotIn("internal.error", failed, label)
                # The gate reports either way, so its verdict says who owns the case:
                # anything ill-typed must be caught here, never downstream by accident.
                self.assertIn("manifest.types", statuses, label)
                if statuses["manifest.types"] == "fail":
                    self.assertIn("manifest.types", failed, label)

    def test_member_topics_must_stay_inside_their_container(self) -> None:
        # A member projected into no topic is a member nothing ever checks.
        manifest = topic_manifest(self.head)
        manifest["boundaries"] = [zone_boundary(member_topics=["start"])]
        report = self.assert_named_failure(topic_document(), manifest, "manifest.topics")
        self.assert_evidence(report, "manifest.topics", "outside its container's topics")

    def test_declaration_order_matches_what_the_document_can_nest(self) -> None:
        # Whatever the manifest validator accepts must be drawable: the declared order
        # has to equal the tree's pre-order, which is the sequence the document opens.
        topics = [
            {"id": "overview", "question": "q"},
            {"id": "start", "question": "q", "parent": "overview"},
            {"id": "deep", "question": "q", "parent": "start"},
            {"id": "validate", "question": "q", "parent": "overview"},
        ]
        manifest = topic_manifest(self.head, topics)
        result, report = self.validate(topic_document(), manifest)
        failed = {check["name"] for check in report["checks"] if check["status"] == "fail"}
        self.assertNotIn("manifest.topics", failed, json.dumps(report, indent=2))

    def test_bug_fix_pr_without_its_fixes_line_is_rejected(self) -> None:
        document, manifest = bug_pr_fixture(self.base, self.head)
        document = document.replace("\nFixes #7\n", "\n")
        result, report = self.validate(document, manifest)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assert_check_failed(report, "changes.fixes_line")

    def test_unaccounted_annotation_is_reported_once(self) -> None:
        manifest = topic_manifest(self.head)
        manifest["annotations"] = [
            {"kind": "BUG", "target": "node:absent", "state": "current", "text": "ghost"}
        ]
        _result, report = self.validate(topic_document(), manifest)
        reporting = [
            check["name"]
            for check in report["checks"]
            if check["status"] == "fail"
            and any("must reference a declared item" in line for line in check["evidence"])
        ]
        self.assertEqual(reporting, ["overview/manifest.shape"], json.dumps(reporting))

    def test_malformed_svg_dimension_reads_as_unmeasured(self) -> None:
        self.assertIsNone(_svg_size('<svg width="1.2.3" height="600"></svg>'))
        self.assertIsNone(_svg_size('<svg viewBox="0 0 1.2.3 65"></svg>'))
        self.assertEqual(_svg_size('<svg width="800" height="600"></svg>'), (800.0, 600.0))

    def test_annotation_rules_apply_to_every_topic(self) -> None:
        # Every topic gets its own change-rule pass: an illegal annotation must be
        # caught wherever its target lives, not only in the topic validated first.
        for target, expected in (("node:load", "overview"), ("node:validate", "start")):
            with self.subTest(target=target):
                manifest = topic_manifest(self.head)
                manifest["annotations"] = [
                    {"kind": "FIX", "target": target, "state": "current", "text": "illegal here"}
                ]
                self.assert_named_failure(
                    topic_document(), manifest, f"{expected}/changes.alignment"
                )

    def test_container_topic_without_a_member_is_rejected(self) -> None:
        # The converse of the subset rule: a boundary claiming a topic none of its
        # members declare would project to members: [] and be reported as though it
        # had no members at all.
        manifest = topic_manifest(self.head)
        boundary = zone_boundary(member_topics=["overview"], target="node:load")
        boundary["topics"] = ["overview", "start"]
        manifest["boundaries"] = [boundary]
        report = self.assert_named_failure(topic_document(), manifest, "manifest.topics")
        self.assert_evidence(report, "manifest.topics", "with no member there")

    def test_undeclared_member_target_is_reported_under_topics(self) -> None:
        # The member sits in a sibling topic, so before the subset rule it projected
        # into no topic at all and its undeclared target was never checked.
        manifest = topic_manifest(self.head)
        manifest["boundaries"] = [zone_boundary(member_topics=["start"], target="node:absent")]
        result, report = self.validate(topic_document(), manifest)
        self.assertEqual(result.returncode, 1, result.stderr)
        reported = [
            line
            for check in report["checks"]
            if check["status"] == "fail"
            for line in check["evidence"]
            if "must reference a declared node or boundary" in line
        ]
        self.assertTrue(reported, json.dumps(report, indent=2))

    def test_unparsed_document_does_not_invent_topic_failures(self) -> None:
        # A well-typed manifest whose topic tree is invalid stops the document pass
        # while validate_manifest still succeeds, so without the guard the per-topic
        # pass would judge an empty diagram and bury the real complaint.
        topics = [
            {"id": "overview", "question": "q"},
            {"id": "start", "question": "q", "parent": "validate"},
            {"id": "validate", "question": "q", "parent": "start"},
        ]
        result, report = self.validate(topic_document(), topic_manifest(self.head, topics))
        self.assertEqual(result.returncode, 1, result.stderr)
        failed = {check["name"] for check in report["checks"] if check["status"] == "fail"}
        self.assertIn("manifest.topics", failed)
        self.assertNotIn("consistency.cross_view", failed, json.dumps(report, indent=2))
        self.assertNotIn("document.structure", failed, json.dumps(report, indent=2))

    def test_dangling_annotation_target_is_rejected_with_topics(self) -> None:
        # Projection must not swallow an annotation the manifest cannot account for.
        ghost = {"kind": "BUG", "target": "node:absent", "state": "current", "text": "ghost"}
        manifest = topic_manifest(self.head)
        manifest["annotations"] = [ghost]
        self.assert_named_failure(topic_document(), manifest, "overview/manifest.shape")

    def test_item_topics_without_a_tree_are_rejected(self) -> None:
        # Without a declared tree nothing else would ever look at these.
        for where in ("nodes", "edges"):
            with self.subTest(collection=where):
                document, manifest = overview_fixture(self.head)
                manifest[where][0]["topics"] = ["ghost_topic"]
                self.assert_named_failure(document, manifest, "manifest.types")

    def test_non_topical_artifacts_keep_their_names(self) -> None:
        document, manifest = architecture_only_fixture(self.head)
        result, report = self.validate(document, manifest)
        self.assertEqual(result.returncode, 0, result.stderr)
        names = sorted(Path(value).name for value in report["artifacts"])
        self.assertIn("architecture-current.png", names)
        self.assertNotIn("architecture-current-overview.png", names)

    def test_unhashable_item_id_under_a_valid_topic_tree_is_named(self) -> None:
        # filter_manifest collects item ids into a set, and it runs before
        # validate_manifest; a valid tree with valid item topics still reaches it.
        for collection in ("nodes", "edges"):
            with self.subTest(collection=collection):
                document, manifest = topic_document(), topic_manifest(self.head)
                if not manifest[collection]:
                    continue
                manifest[collection][0]["id"] = {"unhashable": True}
                self.assert_named_failure(document, manifest, "manifest.types")

    def test_item_topics_unhashable_is_named_not_crashed(self) -> None:
        document, manifest = overview_fixture(self.head)
        manifest["topics"] = [{"id": "overview", "question": "q"}]
        for item in manifest["nodes"] + manifest["edges"]:
            item["topics"] = [["overview"]]
        report = self.assert_named_failure(document, manifest, "manifest.types")
        self.assert_evidence(report, "manifest.types", "must be an array of strings")

    def test_well_typed_topic_trees_still_fail_as_topics(self) -> None:
        # The type gate must not swallow the semantic tree rules.
        cases = {
            "cycle": [{"id": "overview", "question": "q"},
                      {"id": "start", "question": "q", "parent": "validate"},
                      {"id": "validate", "question": "q", "parent": "start"}],
            "second root": [{"id": "overview", "question": "q"}, {"id": "start", "question": "q"}],
            "undeclared parent": [{"id": "overview", "question": "q"},
                                  {"id": "start", "question": "q", "parent": "absent"}],
            "child before parent": [{"id": "overview", "question": "q"},
                                    {"id": "validate", "question": "q", "parent": "start"},
                                    {"id": "start", "question": "q", "parent": "overview"}],
            # Parent-before-child holds, but the document must nest deep inside start,
            # so its pre-order is overview, start, deep, validate.
            "not document pre-order": [{"id": "overview", "question": "q"},
                                       {"id": "start", "question": "q", "parent": "overview"},
                                       {"id": "validate", "question": "q", "parent": "overview"},
                                       {"id": "deep", "question": "q", "parent": "start"}],
        }
        for label, topics in cases.items():
            with self.subTest(tree=label):
                self.assert_named_failure(
                    topic_document(), topic_manifest(self.head, topics), "manifest.topics"
                )

    def test_unexpected_failure_still_writes_a_report(self) -> None:
        # The safety net behind the named checks: callers are told to read
        # validation.json, so even an unforeseen crash has to produce one.
        import validate_diagrams

        case = self.root / "internal-error"
        case.mkdir()
        report_path = case / "validation.json"
        with unittest.mock.patch.object(
            validate_diagrams, "_validate", side_effect=RuntimeError("boom")
        ), unittest.mock.patch.object(validate_diagrams.traceback, "print_exc"):
            code = validate_diagrams.main([
                "--repo", str(self.repo), "--document", str(case / "diagram.md"),
                "--evidence", str(case / "evidence.json"), "--report", str(report_path),
            ])
        self.assertEqual(code, 1)
        report = json.loads(report_path.read_text(encoding="utf-8"))
        self.assertFalse(report["valid"])
        self.assertEqual(report["checks"][0]["name"], "internal.error")
        self.assertIn("boom", report["checks"][0]["message"])

    def test_svg_size_reads_the_viewbox_production_emits(self) -> None:
        # mermaid-cli 11.16.0 emits width="100%" and no height, so the viewBox branch is
        # the one production actually takes.
        real = (
            '<svg id="my-svg" width="100%" xmlns="http://www.w3.org/2000/svg" '
            'class="flowchart" style="max-width: 285.047px;" viewBox="0 0 285.046875 65">'
            "</svg>"
        )
        self.assertEqual(_svg_size(real), (285.046875, 65.0))
        self.assertEqual(_svg_size('<svg width="800px" height="600px"></svg>'), (800.0, 600.0))
        self.assertIsNone(_svg_size("<svg></svg>"))
        self.assertIsNone(_svg_size("no svg here"))

    def test_valid_nested_topics(self) -> None:
        result, report = self.validate(topic_document(), topic_manifest(self.head))
        self.assertEqual(result.returncode, 0, result.stderr + json.dumps(report, indent=2))
        self.assertTrue(report["valid"])

    def test_valid_three_level_topics(self) -> None:
        result, report = self.validate(
            topic_document({"overview": ["start"], "start": ["validate"], "validate": []}),
            topic_manifest(self.head, THREE_LEVEL_TOPICS),
        )
        self.assertEqual(result.returncode, 0, result.stderr + json.dumps(report, indent=2))
        topics = next(check for check in report["checks"] if check["name"] == "manifest.topics")
        self.assertIn("3 level(s) deep", topics["message"])

    def test_fourth_topic_level_is_rejected(self) -> None:
        topics = THREE_LEVEL_TOPICS + [{"id": "load", "question": "how load returns", "parent": "validate"}]
        result, report = self.validate(topic_document(), topic_manifest(self.head, topics))
        self.assertEqual(result.returncode, 1)
        self.assert_evidence(report, "manifest.topics", "the limit is 3")

    def test_topic_parent_cycle_is_rejected(self) -> None:
        topics = [
            {"id": "overview", "question": "how start reaches load"},
            {"id": "start", "question": "how start validates first", "parent": "validate"},
            {"id": "validate", "question": "what validate decides", "parent": "start"},
        ]
        result, report = self.validate(topic_document(), topic_manifest(self.head, topics))
        self.assertEqual(result.returncode, 1)
        self.assert_evidence(report, "manifest.topics", "sits in a parent cycle")

    def test_second_topic_root_is_rejected(self) -> None:
        topics = [
            {"id": "overview", "question": "how start reaches load"},
            {"id": "start", "question": "how start validates first"},
        ]
        result, report = self.validate(topic_document(), topic_manifest(self.head, topics))
        self.assertEqual(result.returncode, 1)
        self.assert_evidence(report, "manifest.topics", "exactly one topic may omit parent")

    def test_item_naming_undeclared_topic_is_rejected(self) -> None:
        data = topic_manifest(self.head)
        data["nodes"][0]["topics"] = ["overview", "absent"]
        result, report = self.validate(topic_document(), data)
        self.assertEqual(result.returncode, 1)
        self.assert_evidence(report, "manifest.topics", "names undeclared topics ['absent']")

    def test_document_nesting_must_match_declared_parent(self) -> None:
        flat = "\n".join([
            "# Diagram", "", "## Architecture", "", "### Current", "",
            *topic_section("overview", []), *topic_section("start", []),
        ])
        result, report = self.validate(flat, topic_manifest(self.head))
        self.assertEqual(result.returncode, 1)
        self.assert_evidence(report, "document.structure", "declares parent 'overview'")

    def test_fence_outside_details_is_rejected(self) -> None:
        document = topic_document().replace("<details>\n<summary><code>overview</code>", "PLAIN", 1)
        result, report = self.validate(document, topic_manifest(self.head))
        self.assertEqual(result.returncode, 1)
        self.assert_evidence(report, "document.structure", "outside a <details> topic section")

    def test_details_without_a_summary_is_rejected(self) -> None:
        document = topic_document().replace(
            "<summary><code>overview</code> \u2014 how start reaches load</summary>\n\n", "", 1
        )
        result, report = self.validate(document, topic_manifest(self.head))
        self.assertEqual(result.returncode, 1)
        self.assert_evidence(report, "document.structure", "must be followed by")

    def test_missing_blank_line_after_summary_is_rejected(self) -> None:
        result, report = self.validate(
            topic_document(blank_after_summary=False), topic_manifest(self.head)
        )
        self.assertEqual(result.returncode, 1)
        self.assert_evidence(report, "document.structure", "blank line after <summary>")

    def test_topic_order_must_follow_the_manifest(self) -> None:
        topics = [
            {"id": "overview", "question": TOPIC_QUESTIONS["overview"]},
            {"id": "validate", "question": TOPIC_QUESTIONS["validate"], "parent": "overview"},
            {"id": "start", "question": TOPIC_QUESTIONS["start"], "parent": "overview"},
        ]
        document = topic_document({"overview": ["start", "validate"], "start": [], "validate": []})
        result, report = self.validate(document, topic_manifest(self.head, topics))
        self.assertEqual(result.returncode, 1)
        self.assert_evidence(report, "document.structure", "topic order must be")

    def test_topic_drawing_a_sibling_element_is_rejected(self) -> None:
        data = topic_manifest(self.head)
        document = topic_document().replace('  load["load"]', '  load["load"]\n  validate["validate"]', 1)
        result, report = self.validate(document, data)
        self.assertEqual(result.returncode, 1)
        self.assert_check_failed(report, "overview/consistency.cross_view")

    def test_each_topic_renders_its_own_artifacts(self) -> None:
        result, report = self.validate(topic_document(), topic_manifest(self.head))
        self.assertEqual(result.returncode, 0, result.stderr + json.dumps(report, indent=2))
        names = sorted(Path(value).name for value in report["artifacts"] if value.endswith(".png"))
        self.assertEqual(names, ["architecture-current-overview.png", "architecture-current-start.png"])

    def validate(
        self, document: str, manifest: object, environment: dict[str, str] | None = None
    ) -> tuple[subprocess.CompletedProcess[str], dict[str, object]]:
        case = self.root / f"case-{len(list(self.root.glob('case-*')))}"
        case.mkdir()
        document_path = case / "diagram.md"
        evidence_path = case / "evidence.json"
        report_path = case / "validation.json"
        document_path.write_text(document, encoding="utf-8")
        evidence_path.write_text(json.dumps(manifest), encoding="utf-8")
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--repo", str(self.repo), "--document", str(document_path),
             "--evidence", str(evidence_path), "--report", str(report_path)],
            text=True, capture_output=True, check=False, env=environment or self.env,
        )
        return result, json.loads(report_path.read_text(encoding="utf-8"))

    def _assert_non_code_call_is_rejected(self, body: str, path: str) -> None:
        (self.repo / path).write_text(f"def fake():\n    {body}\n", encoding="utf-8")
        self._run("git", "add", path)
        self._run("git", "commit", "-q", "-m", f"add {path}")
        revision = self._run("git", "rev-parse", "HEAD").stdout.strip()
        states = [{"id": "current", "label": "Current", "revision": revision, "proposed": False}]
        nodes = [
            node("fake", "fake", ["current"], [
                {"type": "source", "state": "current", "revision": revision, "path": path,
                 "line_start": 1, "line_end": 2, "symbol": "fake", "tokens": ["fake", "load()"]}
            ]),
            node("load", "load", ["current"], [source_evidence("current", revision, "load", 8, 9, "def load")]),
        ]
        edges = [edge("fake_load", "load", "fake", "load", ["current"], [
            {"type": "source", "state": "current", "revision": revision, "path": path,
             "line_start": 1, "line_end": 2, "symbol": "fake", "tokens": ["load()"]}
        ])]
        document = diagrams(
            [("current", "Current")],
            {"current": [f"  fake (Module · {path}:1) — entry", "    └─ load (Module · app.py:8) — result"]},
            {"current": [("fake_load", "fake", "load", "load", sequence_message("load", "load", 8, 9))]},
            {"current": [("fake", "fake"), ("load", "load")]},
        )
        data = manifest(
            {"kind": "overview", "change_kind": "none", "sources": {"repository": "local"}},
            states, nodes, edges,
        )
        result, report = self.validate(document, data)
        self.assertEqual(result.returncode, 1)
        self.assert_check_failed(report, "source.evidence")

    def run_in_process(self, document: str, manifest: object) -> list[tuple[str, str]]:
        """Run the validator in-process and return (check name, status) pairs."""
        import validate_diagrams

        case = self.root / f"inproc-{len(list(self.root.glob('inproc-*')))}"
        case.mkdir()
        (case / "diagram.md").write_text(document, encoding="utf-8")
        (case / "evidence.json").write_text(json.dumps(manifest), encoding="utf-8")
        report_path = case / "validation.json"
        validate_diagrams.main([
            "--repo", str(self.repo), "--document", str(case / "diagram.md"),
            "--evidence", str(case / "evidence.json"), "--report", str(report_path),
        ])
        report = json.loads(report_path.read_text(encoding="utf-8"))
        return [(check["name"], check["status"]) for check in report["checks"]]

    def assert_named_failure(
        self, document: str, manifest: object, expected: str
    ) -> dict[str, object]:
        """A malformed manifest must fail as `expected`, never as a traceback."""
        result, report = self.validate(document, manifest)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertNotIn("Traceback", result.stderr)
        failed = {check["name"] for check in report["checks"] if check["status"] == "fail"}
        self.assertNotIn("internal.error", failed, json.dumps(report, indent=2))
        self.assertIn(expected, failed, json.dumps(report, indent=2))
        return report

    def assert_evidence(self, report: dict[str, object], name: str, fragment: str) -> None:
        self.assert_check_failed(report, name)
        evidence = next(check for check in report["checks"] if check["name"] == name)["evidence"]
        self.assertTrue(any(fragment in line for line in evidence), json.dumps(evidence, indent=2))

    def assert_check_failed(self, report: dict[str, object], name: str) -> None:
        checks = {value["name"]: value for value in report["checks"]}
        self.assertEqual(checks[name]["status"], "fail", json.dumps(checks.get(name), indent=2))

    def _run(self, *command: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(command, cwd=self.repo, text=True, capture_output=True, check=True)

    def _write_fake_mmdc(self) -> None:
        script = self.bin / "fake-mmdc"
        script.write_text(
            "#!/bin/sh\n"
            "while [ \"$#\" -gt 0 ]; do\n"
            "  case \"$1\" in -i) input=$2; shift 2;; -o) output=$2; shift 2;; *) shift;; esac\n"
            "done\n"
            "if grep -q BROKEN \"$input\"; then echo 'Parse error' >&2; exit 1; fi\n"
            ": \"${BOXLITE_FAKE_SVG_SIZE:=800 600}\"\n"
            "set -- $BOXLITE_FAKE_SVG_SIZE\n"
            "{ printf '<svg width=\"%s\" height=\"%s\"><text>' \"$1\" \"$2\"; sed 's/&/\\&amp;/g; s/</\\&lt;/g; s/>/\\&gt;/g' \"$input\"; printf '</text></svg>'; } > \"$output\"\n",
            encoding="utf-8",
        )
        script.chmod(0o755)

    def _write_fake_gh(self) -> None:
        script = self.bin / "gh"
        script.write_text(
            "#!/bin/sh\n"
            f"if [ \"$1\" = pr ]; then printf '%s\\n' '{{\"number\":3,\"title\":\"Change flow\",\"body\":\"Fixes #7\",\"url\":\"https://example/pr/3\",\"baseRefOid\":\"{self.base}\",\"headRefOid\":\"{self.head}\"}}'; else printf '%s\\n' '{{\"number\":7,\"title\":\"Add validation\",\"body\":\"validation behavior stale result\",\"state\":\"OPEN\",\"url\":\"https://example/issues/7\"}}'; fi\n",
            encoding="utf-8",
        )
        script.chmod(0o755)


def source_evidence(state: str, revision: str, symbol: str, start: int, end: int, *tokens: str) -> dict[str, object]:
    return {"type": "source", "state": state, "revision": revision, "path": "app.py", "line_start": start,
            "line_end": end, "symbol": symbol, "tokens": list(tokens)}


def node(item_id: str, label: str, states: list[str], evidence: list[dict[str, object]]) -> dict[str, object]:
    return {"id": item_id, "label": label, "states": states,
            "views": ["architecture", "sequence", "call_graph"], "proposed": False, "evidence": evidence}


def edge(item_id: str, label: str, source: str, target: str, states: list[str], evidence: list[dict[str, object]]) -> dict[str, object]:
    return {"id": item_id, "label": label, "from": source, "to": target, "kind": "call", "states": states,
            "views": ["architecture", "sequence", "call_graph"], "proposed": False, "evidence": evidence}


def boundary(item_id: str, label: str, states: list[str], evidence: list[dict[str, object]],
             members: list[dict[str, object]]) -> dict[str, object]:
    return {"id": item_id, "label": label, "states": states, "views": ["architecture"],
            "proposed": False, "evidence": evidence, "members": members}


def manifest(context: dict[str, object], states: list[dict[str, object]], nodes: list[dict[str, object]],
             edges: list[dict[str, object]], annotations: list[dict[str, object]] | None = None) -> dict[str, object]:
    return {"schema_version": 1, "context": context, "states": states, "nodes": nodes, "edges": edges,
            "annotations": annotations or []}


def sequence_message(
    action: str,
    function: str,
    line_start: int,
    line_end: int,
    *,
    path: str = "app.py",
    namespace: str = "—",
    class_name: str = "—",
) -> str:
    return (
        f"{action}<br/>File: {path}<br/>Namespace: {namespace}<br/>"
        f"Class: {class_name}<br/>Function: {function}<br/>LOC: L{line_start}-L{line_end}"
    )


def diagrams(states: list[tuple[str, str]], state_hops: dict[str, list[str]], state_edges: dict[str, list[tuple[str, str, str, str, str]]],
             state_nodes: dict[str, list[tuple[str, str]]], footer: str = "") -> str:
    parts = ["# Diagram", "", "## Architecture", ""]
    for state_id, label in states:
        parts += [f"### {label}", "", "```mermaid", "flowchart LR"]
        parts += [f'  {item_id}["{item_label}"]' for item_id, item_label in state_nodes[state_id]]
        parts += [f'  {source} {edge_id}@-->|"{edge_label}"| {target}' for edge_id, source, target, edge_label, _sequence_label in state_edges[state_id]]
        parts += ["```", ""]
    parts += ["## Sequence", ""]
    for state_id, label in states:
        parts += [f"### {label}", "", "```mermaid", "sequenceDiagram"]
        parts += [f"  participant {item_id} as {item_label}" for item_id, item_label in state_nodes[state_id]]
        for edge_id, source, target, _edge_label, sequence_label in state_edges[state_id]:
            parts += [f"  %% edge:{edge_id}", f"  {source}->>{target}: {sequence_label}"]
        parts += ["```", ""]
    parts += ["## Call graph", ""]
    for state_id, label in states:
        parts += [f"### {label}", "", "```text", *state_hops[state_id], "```", ""]
    if footer:
        parts += [footer, ""]
    return "\n".join(parts)


def overview_fixture(head: str) -> tuple[str, dict[str, object]]:
    states = [{"id": "current", "label": "Current", "revision": head, "proposed": False}]
    nodes = [
        node("start", "start", ["current"], [source_evidence("current", head, "start", 1, 3, "def start", "load()")]),
        node("load", "load", ["current"], [source_evidence("current", head, "load", 8, 9, "def load")]),
    ]
    edges = [edge("start_load", "load", "start", "load", ["current"],
                  [source_evidence("current", head, "start", 1, 3, "load()")])]
    doc = diagrams([("current", "Current")], {"current": [
        "  start (Module · app.py:1) — entry", "    └─ load (Module · app.py:8) — load result"]},
        {"current": [("start_load", "start", "load", "load", sequence_message("load", "load", 8, 9))]},
        {"current": [("start", "start"), ("load", "load")]})
    return doc, manifest({"kind": "overview", "change_kind": "none", "sources": {"repository": "local"}}, states, nodes, edges)


def architecture_only_fixture(head: str) -> tuple[str, dict[str, object]]:
    document, data = overview_fixture(head)
    data = copy.deepcopy(data)
    data["views"] = ["architecture"]
    for item in data["nodes"] + data["edges"]:
        item["views"] = ["architecture"]
    document = document[:document.index("## Sequence")].rstrip() + "\n"
    return document, data


def contained_architecture_fixture(head: str) -> tuple[str, dict[str, object]]:
    document, data = architecture_only_fixture(head)
    document = """# Diagram

## Architecture

### Current

```mermaid
flowchart TB
subgraph outer["Outer"]
  subgraph inner["Inner"]
    start["start"]
    load["load"]
  end
end
start start_load@-->|"load"| load
```
"""
    data["boundaries"] = [
        boundary(
            "outer",
            "Outer",
            ["current"],
            [source_evidence("current", head, "start", 1, 3, "def start")],
            [{"target": "boundary:inner", "states": ["current"]}],
        ),
        boundary(
            "inner",
            "Inner",
            ["current"],
            [source_evidence("current", head, "load", 8, 9, "def load")],
            [
                {"target": "node:start", "states": ["current"]},
                {"target": "node:load", "states": ["current"]},
            ],
        ),
    ]
    return document, data


def scoped_zone_fixture(head: str) -> tuple[str, dict[str, object]]:
    document, data = contained_architecture_fixture(head)
    document = document.replace(
        "flowchart TB", f"flowchart TB\nclassDef scope_compute {SCOPE_COMPUTE_STYLES}", 1
    )
    document = document.replace(
        'start start_load@-->|"load"| load',
        'start start_load@-->|"load"| load\nclass inner scope_compute',
        1,
    )
    data["boundaries"][1]["scope"] = "compute"
    return document, data


def call_graph_only_fixture(head: str) -> tuple[str, dict[str, object]]:
    document, data = overview_fixture(head)
    data = copy.deepcopy(data)
    data["views"] = ["call_graph"]
    for item in data["nodes"] + data["edges"]:
        item["views"] = ["call_graph"]
    call_graph = document[document.index("## Call graph"):]
    return f"# Diagram\n\n{call_graph}", data


def issue_fixture(head: str) -> tuple[str, dict[str, object]]:
    doc, data = overview_fixture(head)
    data = copy.deepcopy(data)
    data["context"] = {"kind": "issue", "change_kind": "feature", "sources": {"repository": "local", "issue": 7}}
    data["states"] = [
        {"id": "current", "label": "Current", "revision": head, "proposed": False},
        {"id": "expected", "label": "Expected (proposed)", "revision": head, "proposed": True},
    ]
    for item in data["nodes"] + data["edges"]:
        item["states"].append("expected")
        item["evidence"].append(copy.deepcopy(item["evidence"][0]) | {"state": "expected"})
        item["evidence"].append({"type": "issue", "state": "expected", "issue": 7, "tokens": ["validation"]})
    data["annotations"] = [{"kind": "PROPOSED", "target": "edge:start_load", "state": "expected", "text": "validation behavior"}]
    doc = diagrams(
        [("current", "Current"), ("expected", "Expected (proposed)")],
        {"current": ["  start (Module · app.py:1) — entry", "    └─ load (Module · app.py:8) — load result"],
         "expected": ["  start (Module · app.py:1) — entry", "    └─ load (Module · app.py:8) — load result ← PROPOSED: validation behavior"]},
        {"current": [("start_load", "start", "load", "load", sequence_message("load", "load", 8, 9))],
         "expected": [("start_load", "start", "load", "load PROPOSED: validation behavior", sequence_message("load PROPOSED: validation behavior", "load", 8, 9))]},
        {"current": [("start", "start"), ("load", "load")], "expected": [("start", "start"), ("load", "load")]},
    )
    return doc, data


def feature_pr_fixture(base: str, head: str) -> tuple[str, dict[str, object]]:
    states = [{"id": "before", "label": "Before", "revision": base, "proposed": False},
              {"id": "after", "label": "After", "revision": head, "proposed": False}]
    nodes = [
        node("start", "start", ["before", "after"], [source_evidence("before", base, "start", 1, 2, "def start"), source_evidence("after", head, "start", 1, 3, "def start")]),
        node("load", "load", ["before", "after"], [source_evidence("before", base, "load", 4, 5, "def load"), source_evidence("after", head, "load", 8, 9, "def load")]),
        node("validate", "validate ADDED: validate input", ["after"], [source_evidence("after", head, "validate", 5, 6, "def validate")]),
    ]
    edges = [
        edge("start_load", "load", "start", "load", ["before", "after"], [source_evidence("before", base, "start", 1, 2, "load()"), source_evidence("after", head, "start", 1, 3, "load()")]),
        edge("start_validate", "validate ADDED: validate input", "start", "validate", ["after"], [source_evidence("after", head, "start", 1, 3, "validate()")]),
    ]
    annotations = [{"kind": "ADDED", "target": "edge:start_validate", "state": "after", "text": "validate input"}]
    doc = diagrams(
        [("before", "Before"), ("after", "After")],
        {"before": ["  start (Module · app.py:1) — entry", "    └─ load (Module · app.py:4) — load result"],
         "after": ["  start (Module · app.py:1) — entry", "    ├─ validate (Module · app.py:5) — validate input ← ADDED: validate input", "    └─ load (Module · app.py:8) — load result"]},
        {"before": [("start_load", "start", "load", "load", sequence_message("load", "load", 4, 5))],
         "after": [("start_validate", "start", "validate", "validate ADDED: validate input", sequence_message("validate ADDED: validate input", "validate", 5, 6)),
                   ("start_load", "start", "load", "load", sequence_message("load", "load", 8, 9))]},
        {"before": [("start", "start"), ("load", "load")],
         "after": [("start", "start"), ("validate", "validate ADDED: validate input"), ("load", "load")]})
    context = {"kind": "pr", "change_kind": "feature", "sources": {"repository": "local", "pr": 3,
               "base_revision": base, "head_revision": head}}
    return doc, manifest(context, states, nodes, edges, annotations)


def bug_pr_fixture(base: str, head: str) -> tuple[str, dict[str, object]]:
    document, data = feature_pr_fixture(base, head)
    data["context"]["change_kind"] = "bug"
    data["context"]["sources"]["issue"] = 7
    data["annotations"] = [
        {"kind": "BUG", "target": "edge:start_load", "state": "before", "text": "stale result"},
        {"kind": "FIX", "target": "edge:start_validate", "state": "after", "text": "validate input"},
    ]
    next(value for value in data["nodes"] if value["id"] == "validate")["label"] = "validate FIX: validate input"
    next(value for value in data["edges"] if value["id"] == "start_validate")["label"] = "validate FIX: validate input"
    document = document.replace(" — load result\n", " — load result ← BUG: stale result\n", 1)
    document = document.replace('"load"| load', '"load BUG: stale result"| load', 1)
    document = document.replace("load->>load", "load->>load", 1)
    before_sequence = document.index("## Sequence")
    marker_position = document.index("start->>load: load", before_sequence)
    document = document[:marker_position] + document[marker_position:].replace(
        "start->>load: load", "start->>load: load BUG: stale result", 1
    )
    document = document.replace("← ADDED: validate input", "← FIX: validate input")
    document = document.replace("ADDED: validate input", "FIX: validate input")
    document += "\nFixes #7\n"
    return document, data


THREE_LEVEL_TOPICS = [
    {"id": "overview", "question": "how start reaches load"},
    {"id": "start", "question": "how start validates first", "parent": "overview"},
    {"id": "validate", "question": "what validate decides", "parent": "start"},
]
TOPIC_DIAGRAMS = {
    "overview": ['  start["start"]', '  load["load"]', '  start start_load@-->|"load"| load'],
    "start": ['  start["start"]', '  validate["validate"]', '  start start_validate@-->|"validate"| validate'],
    "validate": ['  validate["validate"]'],
}
TOPIC_QUESTIONS = {
    "overview": "how start reaches load",
    "start": "how start validates first",
    "validate": "what validate decides",
}
TOPIC_MEMBERS = {
    "overview": (["start", "load"], ["start_load"]),
    "start": (["start", "validate"], ["start_validate"]),
    "validate": (["validate"], []),
}


def topic_manifest(head: str, topics: list[dict[str, object]] | None = None) -> dict[str, object]:
    topics = topics or [
        {"id": "overview", "question": TOPIC_QUESTIONS["overview"]},
        {"id": "start", "question": TOPIC_QUESTIONS["start"], "parent": "overview"},
    ]
    selected = [topic["id"] for topic in topics]
    states = [{"id": "current", "label": "Current", "revision": head, "proposed": False}]
    nodes = [
        node("start", "start", ["current"],
             [source_evidence("current", head, "start", 1, 3, "def start", "load()", "validate()")]),
        node("load", "load", ["current"], [source_evidence("current", head, "load", 8, 9, "def load")]),
        node("validate", "validate", ["current"],
             [source_evidence("current", head, "validate", 5, 6, "def validate")]),
    ]
    edges = [
        edge("start_load", "load", "start", "load", ["current"],
             [source_evidence("current", head, "start", 1, 3, "load()")]),
        edge("start_validate", "validate", "start", "validate", ["current"],
             [source_evidence("current", head, "start", 1, 3, "validate()")]),
    ]
    for item in nodes + edges:
        item["views"] = ["architecture"]
        item["topics"] = [
            topic for topic in selected
            if item["id"] in TOPIC_MEMBERS.get(topic, ([], []))[0] + TOPIC_MEMBERS.get(topic, ([], []))[1]
        ]
    data = manifest({"kind": "overview", "change_kind": "none", "sources": {"repository": "local"}},
                    states, nodes, edges)
    data["views"] = ["architecture"]
    data["topics"] = topics
    return data


def topic_section(topic: str, children: list[str], *, blank_after_summary: bool = True) -> list[str]:
    lines = [
        "<details>",
        f"<summary><code>{topic}</code> \u2014 {TOPIC_QUESTIONS[topic]}</summary>",
    ]
    if blank_after_summary:
        lines.append("")
    lines += ["```mermaid", "flowchart LR", *TOPIC_DIAGRAMS[topic], "```", ""]
    lines += children
    lines += ["</details>", ""]
    return lines


def topic_document(tree: dict[str, list[str]] | None = None, root: str = "overview", **kwargs) -> str:
    tree = tree if tree is not None else {"overview": ["start"], "start": []}

    def build(topic: str) -> list[str]:
        children: list[str] = []
        for child in tree.get(topic, []):
            children += build(child)
        return topic_section(topic, children, **kwargs)

    return "\n".join(["# Diagram", "", "## Architecture", "", "### Current", "", *build(root)])



def zone_boundary(*, member_topics: list[str], target: str = "node:absent") -> dict[str, object]:
    return {
        "id": "zone", "label": "zone", "states": ["current"], "views": ["architecture"],
        "topics": ["overview"], "proposed": False,
        "evidence": [source_evidence("current", "HEAD", "start", 1, 3, "def start")],
        "members": [
            {"target": "node:start", "states": ["current"], "topics": ["overview"]},
            {"target": target, "states": ["current"], "topics": member_topics},
        ],
    }


TOPIC_DOCUMENT_TEXT = "\n".join([
    "# Diagram", "", "## Architecture", "", "### Current", "",
    "```mermaid", "flowchart LR", '  start["start"]', "```", "",
])

# Every field the pre-validate_manifest passes read, and every wrong type for it.
# Wrong types, and strings of the right type whose format the id rules reject.
MALFORMED_VALUES = (
    None, 5, "x", ["x"], {"x": 1}, [], [["x"]], [{"x": 1}], [None],
    "data-plane", "Overview", "1bad", "", ["data-plane"],
)
MALFORMED_PATHS = (
    ("states", lambda m, v: m.__setitem__("states", v)),
    ("states[0]", lambda m, v: m.__setitem__("states", [v])),
    ("states[0].id", lambda m, v: m["states"][0].__setitem__("id", v)),
    ("states[0].label", lambda m, v: m["states"][0].__setitem__("label", v)),
    ("views", lambda m, v: m.__setitem__("views", v)),
    ("topics", lambda m, v: m.__setitem__("topics", v)),
    ("topics[0]", lambda m, v: m["topics"].__setitem__(0, v)),
    ("topics[0].id", lambda m, v: m["topics"][0].__setitem__("id", v)),
    ("topics[0].id named as parent", lambda m, v: (
        m["topics"][0].__setitem__("id", v), m["topics"][1].__setitem__("parent", v))),
    ("topics[0].question", lambda m, v: m["topics"][0].__setitem__("question", v)),
    ("topics[1].parent", lambda m, v: m["topics"][1].__setitem__("parent", v)),
    ("nodes", lambda m, v: m.__setitem__("nodes", v)),
    ("nodes[0]", lambda m, v: m.__setitem__("nodes", [v])),
    ("nodes[0].id", lambda m, v: m["nodes"][0].__setitem__("id", v)),
    ("nodes[0].topics", lambda m, v: m["nodes"][0].__setitem__("topics", v)),
    ("edges", lambda m, v: m.__setitem__("edges", v)),
    ("boundaries", lambda m, v: m.__setitem__("boundaries", v)),
    ("boundaries[0].id", lambda m, v: m["boundaries"][0].__setitem__("id", v)),
    ("boundaries[0].topics", lambda m, v: m["boundaries"][0].__setitem__("topics", v)),
    ("boundaries[0].members", lambda m, v: m["boundaries"][0].__setitem__("members", v)),
    ("boundaries[0].members[0]", lambda m, v: m["boundaries"][0].__setitem__("members", [v])),
    ("members[0].topics", lambda m, v: m["boundaries"][0]["members"][0].__setitem__("topics", v)),
    ("annotations", lambda m, v: m.__setitem__("annotations", v)),
)


def malformed_manifests(head: str) -> list[tuple[str, dict[str, object]]]:
    base = topic_manifest(head)
    base["boundaries"] = [{
        "id": "zone", "label": "zone", "states": ["current"], "views": ["architecture"],
        "topics": ["overview"], "proposed": False, "evidence": [],
        "members": [{"target": "node:start", "states": ["current"], "topics": ["overview"]}],
    }]
    cases: list[tuple[str, dict[str, object]]] = [("manifest is an array", [])]
    for label, setter in MALFORMED_PATHS:
        for value in MALFORMED_VALUES:
            manifest = copy.deepcopy(base)
            try:
                setter(manifest, value)
            except Exception:  # a path that cannot hold this value is not a case
                continue
            cases.append((f"{label} = {value!r}", manifest))
    return cases

if __name__ == "__main__":
    unittest.main()
