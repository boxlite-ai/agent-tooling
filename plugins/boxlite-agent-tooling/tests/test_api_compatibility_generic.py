"""Generic specification selection and explicit compatibility exceptions."""
import json
import os
from pathlib import Path
import unittest

from test_api_compatibility import RepositoryFixture, command, specification


SKIP_CONFIRMATION = "api compatibility: skip"


class GenericCompatibilityTests(RepositoryFixture, unittest.TestCase):
    def setUp(self):
        super().setUp()
        (self.root / "openapi/box.openapi.yaml").unlink()
        separator = "\n" if os.name != "nt" else " "
        self.paths = ["openapi.yaml", "contracts/service.openapi.yaml", f"specs/space [1]{separator}openapi-v2.yaml"]
        for path in self.paths:
            self.write_at(path, self.spec)
        self.commit_base("generic API contracts")

    def write_at(self, path, spec):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(json.dumps(spec))

    def test_all_matching_files_have_separate_evidence_and_findings(self):
        for path in self.paths:
            changed = specification()
            changed["paths"] = {}
            self.write_at(path, changed)
        result = self.audit("inspect")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual([item["path"] for item in report["specifications"]], sorted(self.paths))
        for item in report["specifications"]:
            artifacts = item["artifacts"]
            self.assertEqual(Path(artifacts["after"]).read_bytes(), (self.root / item["path"]).read_bytes())
            self.assertTrue(json.loads(Path(artifacts["breaking"]).read_text()))
            self.assertIn(item["path"], "\n".join(report["errors"]))

    def test_only_matching_basenames_and_yaml_suffix_are_selected(self):
        excluded = ["openapi/ordinary.yaml", "nested/openapi.yml", "openapi.yaml.bak", "UPPER-OPENAPI.yaml"]
        for path in excluded:
            self.write_at(path, self.spec)
        self.commit_base("unmatched filenames")
        for path in excluded:
            (self.root / path).write_text("not an API")
        ignored = self.root / "ignored-openapi.yaml"
        ignored.write_text("ignored output")
        with (self.root / ".gitignore").open("a") as stream:
            stream.write("ignored-openapi.yaml\n")
        result = self.audit("check", {"OASDIFF_BIN": "/nonexistent/oasdiff"})
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_confirmation_binds_every_changed_path(self):
        self.spec["paths"] = {}
        self.write_at(self.paths[0], self.spec)
        result = self.submit_prompt(SKIP_CONFIRMATION, {})
        self.assertIn("human confirmation recorded", result.stdout, result.stderr)
        self.assertEqual(self.audit().returncode, 0)
        self.write_at(self.paths[1], self.spec)
        self.assertIn("human confirmation required", self.audit().stderr)
        result = self.submit_prompt(SKIP_CONFIRMATION, {})
        self.assertIn("human confirmation recorded", result.stdout)
        command(["git", "add", "."], self.root, check=True)
        self.assertEqual(self.audit("commit").returncode, 0)

    def test_each_changed_contract_must_be_staged(self):
        self.spec["info"]["version"] = "2"
        self.write_at(self.paths[1], self.spec)
        result = self.audit("commit")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("stage the reviewed OpenAPI", result.stderr)
        command(["git", "add", "--", self.paths[1]], self.root, check=True)
        self.assertEqual(self.audit("commit").returncode, 0)

    def test_multi_file_confirmation_survives_unchanged_crlf_contract(self):
        command(["git", "config", "core.autocrlf", "true"], self.root, check=True)
        command(["git", "config", "core.safecrlf", "false"], self.root, check=True)
        unchanged = self.root / self.paths[1]
        unchanged.write_text(json.dumps(self.spec, indent=2) + "\n")
        self.commit_base("multiline contract")
        unchanged.write_bytes(unchanged.read_bytes().replace(b"\n", b"\r\n"))
        self.spec["paths"] = {}
        self.write_at(self.paths[0], self.spec)
        result = self.submit_prompt(SKIP_CONFIRMATION, {})
        self.assertIn("human confirmation recorded", result.stdout, result.stderr)
        command(["git", "add", "."], self.root, check=True)
        command(["git", "-c", "core.hooksPath=/dev/null", "commit", "-m", "confirmed generic change"], self.root, check=True)
        result = self.audit("push")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_pre_push_receipt_cannot_bypass_generic_contract(self):
        base = command(["git", "rev-parse", "HEAD"], self.root, check=True).stdout.strip()
        self.spec["paths"] = {}
        self.write_at(self.paths[1], self.spec)
        command(["git", "add", "."], self.root, check=True)
        command(["git", "-c", "core.hooksPath=/dev/null", "commit", "-m", "breaking generic API"], self.root, check=True)
        head = command(["git", "rev-parse", "HEAD"], self.root, check=True).stdout.strip()
        # Pending restoration must not hide the committed change.
        self.write_at(self.paths[1], specification())
        command(["git", "add", "."], self.root, check=True)
        updates = self.root / ".git/ref-updates"
        updates.write_text(f"refs/heads/feature {head} refs/heads/feature {base}\n")
        script = '''set -uo pipefail
is_agent=1; tooling_root="$1"; repo_root="$2"; stdin_file="$3"
push_is_single_audited_commit() { printf 'already-audited'; }
source /dev/stdin <<<"$(sed -n '/^run_push_audit() {/,/^run_push_audit "/p' "$tooling_root/.githooks/pre-push")"
exit 0
'''
        result = command(["bash", "-c", script, "fixture", str(self.plugin), str(self.root), str(updates)], self.root)
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertIn(self.paths[1], result.stderr)
        self.assertIn("human confirmation required", result.stderr)


class SkipConfirmationTests(RepositoryFixture, unittest.TestCase):
    def test_skip_needs_no_notion_and_recommends_issue_discussion(self):
        self.breaking_change()
        result = self.audit()
        self.assertIn("GitHub issue", result.stderr)
        self.assertIn(SKIP_CONFIRMATION, result.stderr)
        result = self.submit_prompt(SKIP_CONFIRMATION, {"NOTION_TOKEN": ""})
        self.assertIn("human confirmation recorded", result.stdout, result.stderr)
        self.assertEqual(self.audit().returncode, 0)
        record = json.loads((self.root / ".git/api-compatibility.approval.json").read_text())
        self.assertNotIn("notion", record)
        self.assertEqual(record["confirmation"], SKIP_CONFIRMATION)

    def test_old_confirmation_and_non_user_events_cannot_skip(self):
        self.breaking_change()
        for event, prompt in (("UserPromptSubmit", "maintainer confirmed: https://notion.so/" + "a" * 32),
                              ("Stop", SKIP_CONFIRMATION), ("UserPromptSubmit", "do not " + SKIP_CONFIRMATION)):
            with self.subTest(event=event, prompt=prompt):
                self.audit("record", payload={"hook_event_name": event, "session_id": "human", "prompt": prompt})
                self.assertIn("human confirmation required", self.audit().stderr)

    def test_skip_does_not_approve_checker_failure(self):
        self.breaking_change()
        result = self.submit_prompt(SKIP_CONFIRMATION, {"OASDIFF_BIN": "/nonexistent/oasdiff"})
        self.assertIn("confirmation not recorded", result.stdout)
        self.assertFalse((self.root / ".git/api-compatibility.approval.json").exists())
        self.assertIn("human confirmation required", self.audit().stderr)


class UnrelatedRepositoryTests(RepositoryFixture, unittest.TestCase):
    def test_pre_push_without_openapi_does_not_require_remote_objects(self):
        (self.root / "openapi/box.openapi.yaml").unlink()
        self.commit_base("no API contracts")
        head = command(["git", "rev-parse", "HEAD"], self.root, check=True).stdout.strip()
        updates = self.root / ".git/ref-updates"
        updates.write_text(f"refs/heads/feature {head} refs/heads/feature {'a' * 40}\n")
        script = '''set -uo pipefail
is_agent=1; tooling_root="$1"; repo_root="$2"; stdin_file="$3"
push_is_single_audited_commit() { printf 'already-audited'; }
source /dev/stdin <<<"$(sed -n '/^run_push_audit() {/,/^run_push_audit "/p' "$tooling_root/.githooks/pre-push")"
exit 0
'''
        result = command(["bash", "-c", script, "fixture", str(self.plugin), str(self.root), str(updates)], self.root)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("already passed its own audit", result.stderr)
