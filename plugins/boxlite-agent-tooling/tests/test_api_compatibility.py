"""Exercise compatibility enforcement through the commit/push boundary."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

PLUGIN = Path(__file__).resolve().parents[1]


def command(args, cwd, **kwargs):
    return subprocess.run(args, cwd=cwd, capture_output=True, text=True, **kwargs)


def specification():
    return {"openapi": "3.1.1", "info": {"title": "Fixture", "version": "1"},
            "paths": {"/boxes": {"post": {
                "requestBody": {"content": {"application/json": {"schema": {
                    "type": "object", "properties": {"name": {"type": "string"},
                    "enabled": {"type": "boolean", "default": False}}}}}},
                "responses": {"200": {"description": "OK"}}}}}}


def confirmation():
    return "api compatibility: skip"


class RepositoryFixture:
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.plugin = self.root / "tooling"
        shutil.copytree(PLUGIN, self.plugin, symlinks=True)
        # Isolate the deterministic Stop guard from the downstream model audit.
        (self.plugin / ".agents/hooks/audit/preflight-verdict-check.sh").write_text("#!/bin/sh\nexit 0\n")
        (self.root / ".gitignore").write_text("tooling/\n.agents/state/\n")
        for args in (["git", "init", "-b", "main"],
                     ["git", "config", "user.name", "Fixture"],
                     ["git", "config", "user.email", "fixture@example.test"]):
            command(args, self.root, check=True)
        self.spec = specification()
        (self.root / "openapi").mkdir()
        self.write_spec()
        command(["git", "add", "."], self.root, check=True)
        command(["git", "-c", "core.hooksPath=/dev/null", "commit", "-m", "fixture"],
                self.root, check=True)
        command(["git", "checkout", "-b", "feature"], self.root, check=True)

    def write_spec(self):
        (self.root / "openapi/box.openapi.yaml").write_text(json.dumps(self.spec))

    def stop(self):
        payload = {"hook_event_name": "Stop", "session_id": "fixture",
                   "last_assistant_message": "## TL;DR\n\nDone.\n\n## Details\n\nDone."}
        env = dict(os.environ, CLAUDE_PROJECT_DIR=str(self.root),
                   VERDICT_CLASSIFIER_CMD="printf NO", CODEX_BIN="/nonexistent/codex")
        result = command(["bash", str(self.plugin / ".agents/hooks/stop-gate.sh")],
                         self.root, input=json.dumps(payload), env=env, timeout=25)
        return result, [json.loads(line) for line in result.stdout.splitlines() if line.startswith("{")]

    def audit(self, action="check", extra_env=None, payload=None):
        env = dict(os.environ, **(extra_env or {}))
        return command(["bash", str(self.plugin / "scripts/api-compatibility.sh"), action, str(self.root)],
                       self.root, env=env, input=json.dumps(payload or {}), timeout=20)

    def inspection(self, action="inspect"):
        result = self.audit(action)
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertNotIn("obligations", report, "request tests must be judged from native evidence")
        self.assertEqual(len(report["specifications"]), 1)
        spec = report["specifications"][0]
        self.assertIn("artifacts", spec, "the auditor needs reports and specification snapshots")
        files = {name: Path(path) for name, path in spec["artifacts"].items()}
        self.assertEqual(set(files), {"before", "after", "changelog", "breaking", "diff"})
        for path in files.values():
            self.assertTrue(path.is_absolute() and path.is_file(), path)
        return report, files

    def commit_base(self, message):
        command(["git", "add", "."], self.root, check=True)
        command(["git", "-c", "core.hooksPath=/dev/null", "commit", "-m", message], self.root, check=True)
        command(["git", "branch", "-f", "main", "HEAD"], self.root, check=True)

    def body_schema(self):
        return self.spec["paths"]["/boxes"]["post"]["requestBody"]["content"]["application/json"]["schema"]

    def breaking_change(self):
        del self.spec["paths"]["/boxes"]
        self.write_spec()

    def submit_prompt(self, prompt, extra_env):
        payload = {"hook_event_name": "UserPromptSubmit", "session_id": "human", "prompt": prompt}
        env = dict(os.environ, CLAUDE_PROJECT_DIR=str(self.root), **extra_env)
        return command(["bash", str(self.plugin / ".agents/hooks/cancel-verdict-audit.sh")],
                       self.root, input=json.dumps(payload), env=env, timeout=20)



class StopCompatibilityTests(RepositoryFixture, unittest.TestCase):
    # Confirmation follows the reply that shows the change, so only commit/push enforce.
    def test_unconfirmed_breaking_change_does_not_block_stop(self):
        del self.spec["paths"]["/boxes"]
        self.write_spec()
        self.assertIn("human confirmation required", self.audit("check").stderr)
        result, outputs = self.stop()
        reasons = " ".join(str(o.get("reason", "")) for o in outputs if o.get("decision") == "block")
        self.assertNotIn("api-compatibility:", reasons, result.stdout + result.stderr)

    def test_unconfirmed_breaking_change_blocks_commit(self):
        del self.spec["paths"]["/boxes"]
        self.write_spec()
        command(["git", "add", "."], self.root, check=True)
        result = self.audit("commit")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("human confirmation required", result.stderr)


class CompatibilityTests(RepositoryFixture, unittest.TestCase):
    def test_only_the_specification_is_read(self):
        # boxlite tracks submodules and leaves build outputs untracked; neither may block the check.
        sha = command(["git", "rev-parse", "HEAD"], self.root, check=True).stdout.strip()
        command(["git", "update-index", "--add", "--cacheinfo", f"160000,{sha},vendor/sub"], self.root, check=True)
        (self.root / "target").mkdir()
        (self.root / "target/build.bin").write_bytes(b"\0" * 1024)
        os.symlink("/etc/hosts", self.root / "outside-link")
        self.breaking_change()
        result = self.audit()
        self.assertIn("openapi/box.openapi.yaml: 1 breaking API finding", result.stderr)
        self.assertIn("human confirmation required", result.stderr)

    def test_default_change_needs_confirmation_even_without_breaking_findings(self):
        self.body_schema()["properties"]["enabled"]["default"] = True
        self.write_spec()
        result = self.audit("inspect")
        report = json.loads(result.stdout)
        self.assertEqual(json.loads(Path(report["specifications"][0]["artifacts"]["breaking"]).read_text()), [])
        self.assertIn("existing default changes need human confirmation", result.stderr)
        self.assertIn("human confirmation required for change " + report["fingerprint"], result.stderr)

    def test_unchanged_contract_needs_no_oasdiff(self):
        (self.root / "unrelated.txt").write_text("change")
        self.assertEqual(self.audit("check", {"OASDIFF_BIN": "/nonexistent/oasdiff"}).returncode, 0)

    def test_wrong_oasdiff_version_fails_closed(self):
        self.breaking_change()
        fake = self.root / "wrong-oasdiff"
        fake.write_text("#!/bin/sh\nprintf 'oasdiff version 0.0.1\\n'\n")
        fake.chmod(0o755)
        self.assertIn("requires oasdiff 1.33.0", self.audit("check", {"OASDIFF_BIN": str(fake)}).stderr)

    def test_confirmation_binds_the_specification_only(self):
        env = {}
        self.breaking_change()
        result = self.submit_prompt(confirmation(), env)
        self.assertIn("human confirmation recorded", result.stdout)
        self.assertEqual(self.audit("check", env).returncode, 0)
        (self.root / "unrelated.txt").write_text("other files do not invalidate approval")
        self.assertEqual(self.audit("check", env).returncode, 0)
        self.spec["paths"]["/other"] = {"get": {"responses": {"200": {"description": "OK"}}}}
        self.write_spec()
        self.assertIn("human confirmation required", self.audit("check", env).stderr)

    def test_invalid_confirmations_cannot_approve(self):
        env = {}
        self.breaking_change()
        fingerprint = json.loads(self.audit("inspect", env).stdout)["fingerprint"]
        for event, prompt in (("Stop", confirmation()),
                              ("UserPromptSubmit", "https://notion.so/" + "a" * 32),
                              ("UserPromptSubmit", "Someone confirmed: " + confirmation()),
                              ("UserPromptSubmit", f"maintainer confirmed: {fingerprint} https://notion.so/" + "a" * 32)):
            self.audit("record", env, {"hook_event_name": event, "session_id": "human", "prompt": prompt})
            self.assertIn("human confirmation required for change " + fingerprint, self.audit("check", env).stderr)

    def test_approval_accepts_existing_default_change(self):
        env = {}
        self.body_schema()["properties"]["enabled"]["default"] = True
        self.write_spec()
        result = self.audit("record", env, {"hook_event_name": "UserPromptSubmit", "session_id": "human",
                                            "prompt": confirmation()})
        self.assertEqual(result.returncode, 0, result.stderr)
        approved = self.audit("check", env)
        self.assertEqual(approved.returncode, 0, approved.stderr)

    def test_staged_contract_cannot_hide_behind_restored_working_copy(self):
        self.breaking_change()
        command(["git", "add", "openapi/box.openapi.yaml"], self.root, check=True)
        self.spec = specification()
        self.write_spec()
        self.assertNotEqual(self.audit("commit").returncode, 0)

    def test_example_value_named_default_is_not_a_contract_default(self):
        self.spec["paths"]["/boxes"]["post"]["requestBody"]["content"]["application/json"]["example"] = {"default": False}
        self.write_spec()
        self.commit_base("example")
        self.spec["paths"]["/boxes"]["post"]["requestBody"]["content"]["application/json"]["example"]["default"] = True
        self.write_spec()
        self.assertEqual(self.audit().returncode, 0)

    def test_parameter_reordering_does_not_change_defaults(self):
        operation = self.spec["paths"]["/boxes"]["post"]
        operation["parameters"] = [{"name": name, "in": "query", "schema": {"type": "integer", "default": value}}
                                   for name, value in (("first", 1), ("second", 2))]
        self.write_spec()
        self.commit_base("parameters")
        operation["parameters"].reverse()
        self.write_spec()
        result = self.audit()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_retargeted_reference_cannot_hide_default_change(self):
        self.spec["components"] = {"schemas": {"Off": {"type": "boolean", "default": False},
                                                 "On": {"type": "boolean", "default": True}}}
        self.body_schema()["properties"]["enabled"] = {"$ref": "#/components/schemas/Off"}
        self.write_spec()
        self.commit_base("references")
        self.body_schema()["properties"]["enabled"] = {"$ref": "#/components/schemas/On"}
        self.write_spec()
        self.assertIn("existing default changes need human confirmation", self.audit().stderr)


class InspectionEvidenceTests(RepositoryFixture, unittest.TestCase):
    def test_native_reports_and_exact_snapshots_survive_workspace_changes(self):
        self.body_schema()["properties"]["extra"] = {"type": ["boolean", "null"], "default": False}
        self.write_spec()
        report, files = self.inspection()
        captured = {key: path.read_bytes() for key, path in files.items()}
        base = subprocess.run(["git", "show", f"{report['base']}:openapi/box.openapi.yaml"],
                              cwd=self.root, capture_output=True, check=True).stdout
        self.assertEqual(captured["before"], base)
        self.assertEqual(captured["after"], (self.root / "openapi/box.openapi.yaml").read_bytes())
        self.assertLess(len(json.dumps(report)), 4096)
        config = self.root / "oasdiff-config.json"
        config.write_text("{}")
        env = {k: v for k, v in os.environ.items() if not k.startswith("OASDIFF_")}
        for action in ("changelog", "breaking", "diff"):
            result = command([os.environ.get("OASDIFF_BIN", "oasdiff"), action,
                              "before.yaml", "after.yaml", "--config", str(config),
                              "--allow-external-refs=false", "--format", "json"], files["before"].parent, env=env)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(captured[action]), json.loads(result.stdout))
        self.body_schema()["properties"]["another"] = {"type": "string"}
        self.write_spec()
        _report, second = self.inspection()
        self.assertNotEqual(files["after"], second["after"])
        self.assertEqual({key: path.read_bytes() for key, path in files.items()}, captured)
        self.assertEqual(second["after"].read_bytes(), (self.root / "openapi/box.openapi.yaml").read_bytes())

    def test_content_parameter_keeps_default_and_nullability_evidence(self):
        self.spec["paths"]["/boxes"]["parameters"] = [
            {"name": "scope", "in": "query", "schema": {"type": "string"}}]
        self.spec["paths"]["/boxes"]["post"]["parameters"] = [
            {"name": "verbose", "in": "query", "content": {
                "application/json": {"schema": {"type": "boolean", "default": False}}}}]
        self.write_spec()
        _report, files = self.inspection()
        after = json.loads(files["after"].read_text())
        schema = after["paths"]["/boxes"]["post"]["parameters"][0]["content"]["application/json"]["schema"]
        self.assertEqual(schema, {"type": "boolean", "default": False})
        self.assertEqual(after["paths"]["/boxes"]["parameters"][0]["name"], "scope")
        changes = json.loads(files["changelog"].read_text())
        self.assertEqual(sorted(c["id"] for c in changes), [
            "new-optional-request-default-parameter-to-existing-path", "new-optional-request-parameter"])

    def test_shared_readonly_field_keeps_response_classification(self):
        self.spec["components"] = {"schemas": {"Box": self.body_schema()}}
        operation = self.spec["paths"]["/boxes"]["post"]
        operation["requestBody"]["content"]["application/json"]["schema"] = {"$ref": "#/components/schemas/Box"}
        operation["responses"]["200"]["content"] = {"application/json": {"schema": {"$ref": "#/components/schemas/Box"}}}
        self.write_spec()
        self.commit_base("shared schema")
        self.spec["components"]["schemas"]["Box"]["properties"]["createdAt"] = {"type": "string", "readOnly": True}
        self.write_spec()
        _report, files = self.inspection()
        self.assertEqual([c["id"] for c in json.loads(files["changelog"].read_text())], ["response-optional-property-added"])
        after = json.loads(files["after"].read_text())
        self.assertTrue(after["components"]["schemas"]["Box"]["properties"]["createdAt"]["readOnly"])

    def test_readonly_ancestor_remains_available_to_the_auditor(self):
        self.body_schema()["properties"]["metadata"] = {"type": "object", "readOnly": True, "properties": {"id": {"type": "string"}}}
        self.write_spec()
        self.commit_base("readonly metadata")
        self.body_schema()["properties"]["metadata"]["properties"]["createdAt"] = {"type": "string"}
        self.write_spec()
        _report, files = self.inspection()
        # Native findings can include this child; the original schema supplies its read-only context.
        self.assertIn("new-optional-request-property", [c["id"] for c in json.loads(files["changelog"].read_text())])
        after = json.loads(files["after"].read_text())
        metadata = after["paths"]["/boxes"]["post"]["requestBody"]["content"]["application/json"]["schema"]["properties"]["metadata"]
        self.assertTrue(metadata["readOnly"])
        self.assertEqual(metadata["properties"]["createdAt"], {"type": "string"})

    def test_response_only_schema_needs_no_generated_request_tests(self):
        response = {"type": "object", "properties": {"name": {"type": "string"}}}
        self.spec["paths"]["/boxes"]["post"]["responses"]["200"]["content"] = {"application/json": {"schema": response}}
        self.write_spec()
        self.commit_base("response schema")
        response["properties"]["createdAt"] = {"type": "string"}
        self.write_spec()
        _report, files = self.inspection()
        self.assertEqual([c["id"] for c in json.loads(files["changelog"].read_text())], ["response-optional-property-added"])
        before, after = (json.loads(files[key].read_text())["paths"]["/boxes"]["post"] for key in ("before", "after"))
        self.assertEqual(before["requestBody"], after["requestBody"])

    def test_shared_writable_field_keeps_each_affected_operation(self):
        self.spec["components"] = {"schemas": {"Create": self.body_schema()}}
        self.spec["paths"]["/boxes"]["post"]["requestBody"]["content"]["application/json"]["schema"] = {"$ref": "#/components/schemas/Create"}
        self.spec["paths"]["/copies"] = self.spec["paths"]["/boxes"]
        self.write_spec()
        self.commit_base("shared requests")
        self.spec["components"]["schemas"]["Create"]["properties"]["extra"] = {"type": "boolean"}
        self.write_spec()
        _report, files = self.inspection()
        changes = json.loads(files["changelog"].read_text())
        self.assertEqual(sorted((c["operation"], c["path"], c["id"]) for c in changes), [
            ("POST", "/boxes", "new-optional-request-property"), ("POST", "/copies", "new-optional-request-property")])

    def test_conditional_schema_is_preserved_for_auditor_review(self):
        self.body_schema()["properties"]["extra"] = {"if": {"type": "string"}, "then": {"minLength": 1}}
        self.write_spec()
        _report, files = self.inspection()
        after = json.loads(files["after"].read_text())
        schema = after["paths"]["/boxes"]["post"]["requestBody"]["content"]["application/json"]["schema"]
        self.assertEqual(schema["properties"]["extra"], {"if": {"type": "string"}, "then": {"minLength": 1}})

    def test_malformed_native_diff_blocks_inspection(self):
        executable = shutil.which(os.environ.get("OASDIFF_BIN", "oasdiff"))
        wrapper = self.root / "invalid-diff"
        wrapper.write_text(f"#!{sys.executable}\nimport os, sys\n"
                           "if sys.argv[1] == 'diff':\n print('[]')\nelse:\n"
                           f" os.execv({executable!r}, [{executable!r}, *sys.argv[1:]])\n")
        wrapper.chmod(0o755)
        self.body_schema()["properties"]["extra"] = {"type": "boolean"}
        self.write_spec()
        result = self.audit("inspect", {"OASDIFF_BIN": str(wrapper)})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid oasdiff diff", result.stderr)


class LineEndingCompatibilityTests(RepositoryFixture, unittest.TestCase):
    def setUp(self):
        super().setUp()
        command(["git", "config", "core.autocrlf", "true"], self.root, check=True)
        command(["git", "config", "core.safecrlf", "false"], self.root, check=True)

    def write_formatted_spec(self, newline):
        content = (json.dumps(self.spec, indent=2) + "\n").encode()
        (self.root / "openapi/box.openapi.yaml").write_bytes(content.replace(b"\n", newline))

    def check_push_gates(self, expected_status):
        base = command(["git", "rev-parse", "main"], self.root, check=True).stdout.strip()
        head = command(["git", "rev-parse", "HEAD"], self.root, check=True).stdout.strip()
        for action in ("push", "push-ref"):
            with self.subTest(action=action):
                args = ["bash", str(self.plugin / "scripts/api-compatibility.sh"), action, str(self.root)]
                if action == "push-ref":
                    args.extend([head, base])
                result = command(args, self.root)
                self.assertEqual(result.returncode, expected_status, result.stderr)
                if expected_status:
                    self.assertIn("human confirmation required", result.stderr)

    def test_crlf_confirmation_survives_git_normalization(self):
        self.body_schema()["properties"]["enabled"]["default"] = True
        self.body_schema()["properties"]["name"]["default"] = "first\r\nsecond"
        self.write_formatted_spec(b"\r\n")
        result = self.submit_prompt(confirmation(), {})
        self.assertIn("human confirmation recorded", result.stdout, result.stderr)
        _report, files = self.inspection()
        working = (self.root / "openapi/box.openapi.yaml").read_bytes()
        self.assertIn(b"\r\n", working)
        self.assertEqual(files["after"].read_bytes(), working)

        command(["git", "add", "openapi/box.openapi.yaml"], self.root, check=True)
        staged = subprocess.run(["git", "show", ":openapi/box.openapi.yaml"],
                                cwd=self.root, capture_output=True, check=True).stdout
        self.assertNotIn(b"\r", staged)
        self.assertEqual(staged, working.replace(b"\r\n", b"\n"))
        result = self.audit("commit")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.write_formatted_spec(b"\n")
        with self.subTest(action="commit", working_copy="LF"):
            result = self.audit("commit")
            self.assertEqual(result.returncode, 0, result.stderr)

        command(["git", "-c", "core.hooksPath=/dev/null", "commit", "-m", "confirmed default change"],
                self.root, check=True)
        committed = subprocess.run(["git", "show", "HEAD:openapi/box.openapi.yaml"],
                                   cwd=self.root, capture_output=True, check=True).stdout
        self.assertEqual(committed, staged)
        self.check_push_gates(0)

        # Escaped line breaks are string values, not physical line endings.
        self.body_schema()["properties"]["name"]["default"] = "first\nsecond"
        self.write_formatted_spec(b"\n")
        command(["git", "add", "openapi/box.openapi.yaml"], self.root, check=True)
        result = self.audit("commit")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("human confirmation required", result.stderr)
        command(["git", "-c", "core.hooksPath=/dev/null", "commit", "-m", "unconfirmed string default"],
                self.root, check=True)
        self.check_push_gates(1)


class PushCompatibilityTests(RepositoryFixture, unittest.TestCase):
    def commit_breaking_change(self):
        base = command(["git", "rev-parse", "HEAD"], self.root, check=True).stdout.strip()
        del self.spec["paths"]["/boxes"]
        self.write_spec()
        command(["git", "add", "."], self.root, check=True)
        command(["git", "-c", "core.hooksPath=/dev/null", "commit", "-m", "breaking change"], self.root, check=True)
        head = command(["git", "rev-parse", "HEAD"], self.root, check=True).stdout.strip()
        return base, head

    def test_push_ref_checks_committed_api(self):
        base, head = self.commit_breaking_change()
        result = command(["bash", str(self.plugin / "scripts/api-compatibility.sh"), "push-ref", str(self.root), head, base], self.root)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("human confirmation required", result.stderr)

    def test_push_blocks_committed_breaking_change_after_local_restore(self):
        base, head = self.commit_breaking_change()
        self.spec = specification()
        self.write_spec()
        for staged in (False, True):
            if staged:
                command(["git", "add", "openapi/box.openapi.yaml"], self.root, check=True)
            for action in ("push", "push-ref"):
                with self.subTest(staged=staged, action=action):
                    args = ["bash", str(self.plugin / "scripts/api-compatibility.sh"), action, str(self.root)]
                    if action == "push-ref":
                        args.extend([head, base])
                    result = command(args, self.root)
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                    self.assertIn("human confirmation required", result.stderr)

    def test_push_approval_matches_committed_specification_despite_local_edits(self):
        base, head = self.commit_breaking_change()
        env = {}
        recorded = self.submit_prompt(confirmation(), env)
        self.assertIn("human confirmation recorded", recorded.stdout)
        self.spec = specification()
        self.body_schema()["properties"]["enabled"]["default"] = True
        self.write_spec()
        command(["git", "add", "openapi/box.openapi.yaml"], self.root, check=True)
        for action in ("push", "push-ref"):
            with self.subTest(action=action):
                args = ["bash", str(self.plugin / "scripts/api-compatibility.sh"), action, str(self.root)]
                if action == "push-ref":
                    args.extend([head, base])
                result = command(args, self.root, env=dict(os.environ, **env))
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_push_rejects_approval_for_a_different_committed_specification(self):
        base, _head = self.commit_breaking_change()
        env = {}
        recorded = self.submit_prompt(confirmation(), env)
        self.assertIn("human confirmation recorded", recorded.stdout)
        approved_spec = json.dumps(self.spec)
        self.spec["info"]["version"] = "2"
        self.write_spec()
        command(["git", "add", "openapi/box.openapi.yaml"], self.root, check=True)
        command(["git", "-c", "core.hooksPath=/dev/null", "commit", "-m", "revise API contract"], self.root, check=True)
        head = command(["git", "rev-parse", "HEAD"], self.root, check=True).stdout.strip()
        (self.root / "openapi/box.openapi.yaml").write_text(approved_spec)
        result = command(["bash", str(self.plugin / "scripts/api-compatibility.sh"), "push-ref", str(self.root), head, base], self.root)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("human confirmation required", result.stderr)

    def test_push_ref_keeps_selected_commit_if_head_moves_before_python(self):
        base, head = self.commit_breaking_change()
        self.spec = specification()
        self.spec["info"]["version"] = "pending"
        self.write_spec()
        directory = self.root / "bin"
        directory.mkdir()
        # Move HEAD at the shell/Python boundary; classification still runs real code.
        move_head = [shutil.which("git"), "-C", str(self.root), "update-ref", "refs/heads/feature", base]
        wrapper = directory / "python3"
        wrapper.write_text(f"#!{sys.executable}\nimport os, subprocess, sys\n"
                           f"subprocess.run({move_head!r}, check=True)\n"
                           f"os.execv({sys.executable!r}, [{sys.executable!r}, *sys.argv[1:]])\n")
        wrapper.chmod(0o755)
        env = dict(os.environ, PATH=str(directory) + os.pathsep + os.environ["PATH"])
        result = command(["bash", str(self.plugin / "scripts/api-compatibility.sh"), "push-ref", str(self.root), head, base], self.root, env=env)
        self.assertEqual(command(["git", "rev-parse", "HEAD"], self.root, check=True).stdout.strip(), base)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("human confirmation required", result.stderr)

    def test_inspect_push_reports_committed_evidence(self):
        self.body_schema()["properties"]["committed"] = {"type": "boolean", "default": False}
        self.write_spec()
        command(["git", "add", "openapi/box.openapi.yaml"], self.root, check=True)
        command(["git", "-c", "core.hooksPath=/dev/null", "commit", "-m", "add optional request field"], self.root, check=True)
        self.spec = specification()
        self.body_schema()["properties"]["pending"] = {"type": "string"}
        self.write_spec()
        _report, files = self.inspection("inspect-push")
        committed = subprocess.run(["git", "show", "HEAD:openapi/box.openapi.yaml"],
                                   cwd=self.root, capture_output=True, check=True).stdout
        self.assertEqual(files["after"].read_bytes(), committed)
        changes = json.loads(files["changelog"].read_text())
        self.assertIn("committed", changes[0]["text"])
        self.assertNotIn("pending", files["diff"].read_text())

    def test_other_api_ref_must_be_checked_out(self):
        base, head = self.commit_breaking_change()
        command(["git", "checkout", "main"], self.root, check=True)
        result = command(["bash", str(self.plugin / "scripts/api-compatibility.sh"), "push-ref", str(self.root), head, base], self.root)
        self.assertIn("check out and audit", result.stderr)

    def test_deleted_ref_is_not_checked(self):
        base, _head = self.commit_breaking_change()
        result = command(["bash", str(self.plugin / "scripts/api-compatibility.sh"), "push-ref", str(self.root), "0" * 40, base], self.root)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_commit_audit_receipt_does_not_bypass_api_push_gate(self):
        base, head = self.commit_breaking_change()
        self.spec = specification()
        self.write_spec()
        command(["git", "add", "openapi/box.openapi.yaml"], self.root, check=True)
        updates = self.root / ".git/ref-updates"
        updates.write_text(f"refs/heads/feature {head} refs/heads/feature {base}\n")
        # Exercise the real hook function; only the unrelated auditor receipt is stubbed.
        script = '''set -uo pipefail
is_agent=1; tooling_root="$1"; repo_root="$2"; stdin_file="$3"
push_is_single_audited_commit() { printf 'already-audited'; }
source /dev/stdin <<<"$(sed -n '/^run_push_audit() {/,/^run_push_audit "/p' "$tooling_root/.githooks/pre-push")"
exit 0
'''
        result = command(["bash", "-c", script, "fixture", str(self.plugin), str(self.root), str(updates)], self.root)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("human confirmation required", result.stderr)

    def test_push_ignores_staged_specification_that_is_not_in_head(self):
        self.breaking_change()
        command(["git", "add", "."], self.root, check=True)
        result = self.audit("push", {"OASDIFF_BIN": "/nonexistent/oasdiff"})
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
