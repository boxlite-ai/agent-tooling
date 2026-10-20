"""Exercise compatibility enforcement through the commit/push boundary."""
import json
import os
from pathlib import Path
import shutil
import subprocess
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


def confirmation(fingerprint, phrase="maintainer confirmed"):
    return f"{phrase}: {fingerprint} https://notion.so/" + "a" * 32


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

    def audit(self, action="test", extra_env=None, payload=None):
        env = dict(os.environ, **(extra_env or {}))
        return command(["bash", str(self.plugin / "scripts/api-compatibility.sh"), action, str(self.root)],
                       self.root, env=env, input=json.dumps(payload or {}), timeout=20)

    def optional_parameter(self, behavior="correct", nullable=True):
        (self.root / "sdk.py").write_text(
            "import json, urllib.request\n"
            "def create(url):\n"
            "    req=urllib.request.Request(url+'/boxes',data=json.dumps({'name':'test'}).encode(),headers={'Content-Type':'application/json'})\n"
            "    return urllib.request.urlopen(req).read()\n")
        (self.root / "adapter.py").write_text(
            "import importlib.util, json, os\n"
            "from pathlib import Path\n"
            "spec=importlib.util.spec_from_file_location('sdk',Path(os.environ['API_COMPAT_SDK_ROOT'])/'sdk.py')\n"
            "sdk=importlib.util.module_from_spec(spec); spec.loader.exec_module(sdk)\n"
            "case=json.loads(os.environ['API_COMPAT_INPUT'])\n"
            "kwargs={} if case['case']=='omitted' else {'extra':case['value']}\n"
            "sdk.create(os.environ['API_COMPAT_URL'],**kwargs)\n")
        (self.root / ".agent-tooling").mkdir(exist_ok=True)
        self.config = {"baseRef": "main", "sdks": [{"name": "python", "paths": ["sdk.py"],
                        "command": ["python3", "adapter.py"]}], "features": {"POST /boxes body/extra": {
                        "nonDefault": True, "nullIsOmitted": True,
                        "response": {"status": 200, "body": {"id": "box"}}}}}
        self.write_config()
        command(["git", "add", "."], self.root, check=True)
        command(["git", "-c", "core.hooksPath=/dev/null", "commit", "-m", "old SDK"], self.root, check=True)
        command(["git", "branch", "-f", "main", "HEAD"], self.root, check=True)
        schema = self.spec["paths"]["/boxes"]["post"]["requestBody"]["content"]["application/json"]["schema"]
        schema["properties"]["extra"] = {"type": ["boolean", "null"] if nullable else "boolean", "default": False}
        self.write_spec()
        serializations = {
            "correct": "    if extra is not None and extra is not False: body['extra']=extra\n",
            "send-default": "    body['extra']=extra\n",
            "drop-all": "",
            "wrong-type": "    if extra: body['extra']=1\n",
        }
        (self.root / "sdk.py").write_text(
            "import json, urllib.request\n"
            "def create(url, extra=None):\n"
            "    body={'name':'test'}\n" + serializations[behavior] +
            "    req=urllib.request.Request(url+'/boxes',data=json.dumps(body).encode(),headers={'Content-Type':'application/json'})\n"
            "    return urllib.request.urlopen(req).read()\n")

    def write_config(self):
        (self.root / ".agent-tooling/api-compatibility.json").write_text(json.dumps(self.config))

    def submit_prompt(self, prompt, extra_env):
        payload = {"hook_event_name": "UserPromptSubmit", "session_id": "human", "prompt": prompt}
        env = dict(os.environ, CLAUDE_PROJECT_DIR=str(self.root), **extra_env)
        return command(["bash", str(self.plugin / ".agents/hooks/cancel-verdict-audit.sh")],
                       self.root, input=json.dumps(payload), env=env, timeout=20)

    def notion_env(self):
        directory = self.root / "bin"
        directory.mkdir(exist_ok=True)
        fake = directory / "curl"
        fake.write_text("#!/usr/bin/env python3\nimport json, sys\nsys.stdin.read()\n"
                        "if any('/pages/' in a for a in sys.argv):\n"
                        " print(json.dumps({'object':'page','id':'a'*32,'archived':False}))\n"
                        "else:\n"
                        " blocks=[]\n"
                        " for kind,text in [('heading_2','TL;DR'),('paragraph','Approve this API change.'),('heading_2','Details'),('paragraph','Reviewed compatibility impact.')]:\n"
                        "  blocks.append({'type':kind,'has_children':False,kind:{'rich_text':[{'plain_text':text}]}})\n"
                        " print(json.dumps({'object':'list','has_more':False,'results':blocks}))\n")
        fake.chmod(0o755)
        return {"PATH": str(directory) + os.pathsep + os.environ["PATH"], "NOTION_TOKEN": "fixture-token"}


class StopCompatibilityTests(RepositoryFixture, unittest.TestCase):
    # Confirmation needs the reply that shows the digest, so only commit/push enforce.
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


class CompatibilityExecutionTests(RepositoryFixture, unittest.TestCase):
    def test_real_oasdiff_and_local_sdk_requests_pass(self):
        self.optional_parameter()
        result = self.audit()
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(len(report["passed"]), 4)
        self.assertEqual(report["required"], report["passed"])
        self.assertEqual(self.audit("check").returncode, 0)

    def test_in_repository_symlinks_are_snapshotted(self):
        # Consumers such as boxlite track symlinked docs; both snapshots must keep them as links.
        (self.root / "lib").mkdir()
        os.symlink("../sdk.py", self.root / "lib/sdk.py")
        self.optional_parameter()
        adapter = (self.root / "adapter.py").read_text()
        (self.root / "adapter.py").write_text(adapter.replace("/'sdk.py'", "/'lib/sdk.py'"))
        result = self.audit()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(json.loads(result.stdout)["passed"]), 4)

    def test_symlink_leaving_the_repository_is_rejected(self):
        self.optional_parameter()
        for name, target in (("absolute", "/etc/hosts"), ("relative", "../outside")):
            with self.subTest(name):
                link = self.root / name
                os.symlink(target, link)
                try:
                    self.assertIn("symlink leaves the repository", self.audit().stderr)
                finally:
                    link.unlink()

    def test_sending_defaults_is_rejected(self):
        self.optional_parameter("send-default")
        result = self.audit()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("request differs from pre-change SDK", result.stderr)

    def test_dropping_every_value_is_rejected(self):
        self.optional_parameter("drop-all")
        result = self.audit()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requested value missing", result.stderr)

    def test_boolean_is_not_equivalent_to_integer(self):
        self.optional_parameter("wrong-type")
        result = self.audit()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requested value missing", result.stderr)

    def test_missing_and_stale_execution_block(self):
        self.optional_parameter()
        self.assertIn("missing or stale SDK cases", self.audit("check").stderr)
        self.assertEqual(self.audit().returncode, 0)
        with (self.root / "sdk.py").open("a") as sdk:
            sdk.write("\n# changed after execution\n")
        self.assertIn("missing or stale SDK cases", self.audit("check").stderr)

    def test_missing_declaration_cannot_remove_required_case(self):
        self.optional_parameter()
        self.config["features"] = {}
        self.write_config()
        self.assertIn("declare nonDefault", self.audit().stderr)

    def test_null_semantics_must_be_declared(self):
        self.optional_parameter()
        del self.config["features"]["POST /boxes body/extra"]["nullIsOmitted"]
        self.write_config()
        self.assertIn("declare nullIsOmitted", self.audit().stderr)

    def test_non_nullable_parameter_has_no_null_case(self):
        self.optional_parameter(nullable=False)
        del self.config["features"]["POST /boxes body/extra"]["nullIsOmitted"]
        self.write_config()
        result = self.audit()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(json.loads(result.stdout)["required"]), 3)

    def test_sdk_none_is_tested_even_when_wire_schema_disallows_null(self):
        self.optional_parameter(nullable=False)
        result = self.audit()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(json.loads(result.stdout)["required"]), 4)

    def test_sdk_none_cannot_leak_null_into_a_non_nullable_request(self):
        self.optional_parameter(nullable=False)
        sdk = self.root / "sdk.py"
        sdk.write_text(sdk.read_text().replace("def create(url, extra=None):", "def create(url, extra=False):")
                       .replace("extra is not None and extra is not False", "extra is not False"))
        result = self.audit()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("request differs from pre-change SDK: POST /boxes body/extra null", result.stderr)

    def test_nullable_union_requires_null_case(self):
        self.optional_parameter()
        schema = self.spec["paths"]["/boxes"]["post"]["requestBody"]["content"]["application/json"]["schema"]
        schema["properties"]["extra"] = {"anyOf": [{"type": "boolean"}, {"type": "null"}], "default": False}
        self.write_spec()
        result = self.audit()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(json.loads(result.stdout)["required"]), 4)

    def test_explicit_null_with_distinct_meaning_is_transmitted(self):
        self.optional_parameter()
        self.config["features"]["POST /boxes body/extra"]["nullIsOmitted"] = False
        self.write_config()
        sdk = self.root / "sdk.py"
        sdk.write_text(sdk.read_text().replace("def create(url, extra=None):", "_missing=object()\ndef create(url, extra=_missing):")
                       .replace("extra is not None and extra is not False", "extra is not _missing and extra is not False"))
        result = self.audit()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_server_only_change_does_not_require_sdk_changes(self):
        self.optional_parameter()
        old = command(["git", "show", "main:sdk.py"], self.root, check=True).stdout
        (self.root / "sdk.py").write_text(old)
        result = self.audit()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["required"], [])

    def test_adapter_success_without_requests_is_not_evidence(self):
        self.optional_parameter()
        (self.root / "adapter.py").write_text("print('PASS')\n")
        self.assertIn("no HTTP request", self.audit().stderr)

    def test_adapter_failure_is_not_evidence(self):
        self.optional_parameter()
        (self.root / "adapter.py").write_text("raise SystemExit(7)\n")
        self.assertIn("adapter exited 7", self.audit().stderr)

    def test_timeout_is_bounded(self):
        self.optional_parameter()
        self.config["timeoutSeconds"] = 1
        self.write_config()
        (self.root / "adapter.py").write_text("import time\ntime.sleep(30)\n")
        self.assertIn("adapter timed out", self.audit().stderr)

    def test_default_change_needs_confirmation_even_without_breaking_findings(self):
        schema = self.spec["paths"]["/boxes"]["post"]["requestBody"]["content"]["application/json"]["schema"]
        schema["properties"]["enabled"]["default"] = True
        self.write_spec()
        result = self.audit()
        report = json.loads(result.stdout)
        self.assertEqual(report["breaking"], [])
        self.assertIn("existing default changes need human confirmation", result.stderr)
        self.assertIn("human confirmation required for change " + report["fingerprint"], result.stderr)

    def test_unchanged_contract_needs_no_oasdiff(self):
        (self.root / "unrelated.txt").write_text("change")
        self.assertEqual(self.audit("check", {"OASDIFF_BIN": "/nonexistent/oasdiff"}).returncode, 0)

    def test_wrong_oasdiff_version_fails_closed(self):
        del self.spec["paths"]["/boxes"]
        self.write_spec()
        fake = self.root / "wrong-oasdiff"
        fake.write_text("#!/bin/sh\nprintf 'oasdiff version 0.0.1\\n'\n")
        fake.chmod(0o755)
        self.assertIn("requires oasdiff 1.33.0", self.audit("check", {"OASDIFF_BIN": str(fake)}).stderr)

    def test_user_confirmation_requires_notion_and_expires_on_source_change(self):
        env = self.notion_env()
        del self.spec["paths"]["/boxes"]
        self.write_spec()
        initial = self.audit("inspect", env)
        self.assertIn("human confirmation required", initial.stderr)
        fingerprint = json.loads(initial.stdout)["fingerprint"]
        payload = {"hook_event_name": "UserPromptSubmit", "session_id": "human",
                   "prompt": confirmation(fingerprint)}
        result = self.audit("record", env, payload)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.audit("check", env).returncode, 0)
        (self.root / "another-change.txt").write_text("new scope")
        self.assertIn("human confirmation required", self.audit("check", env).stderr)

    def test_notion_link_or_non_user_event_cannot_approve(self):
        env = self.notion_env()
        del self.spec["paths"]["/boxes"]
        self.write_spec()
        fingerprint = json.loads(self.audit("inspect", env).stdout)["fingerprint"]
        for event, prompt in (("Stop", confirmation(fingerprint)),
                              ("UserPromptSubmit", "https://notion.so/" + "a" * 32)):
            self.audit("record", env, {"hook_event_name": event, "session_id": "human", "prompt": prompt})
            self.assertIn("human confirmation required", self.audit("check", env).stderr)

    def test_confirmation_must_come_from_the_maintainer(self):
        env = self.notion_env()
        del self.spec["paths"]["/boxes"]
        self.write_spec()
        fingerprint = json.loads(self.audit("inspect", env).stdout)["fingerprint"]
        self.audit("record", env, {"hook_event_name": "UserPromptSubmit", "session_id": "human",
                                   "prompt": confirmation(fingerprint, "Someone confirmed")})
        self.assertIn("human confirmation required for change " + fingerprint,
                      self.audit("check", env).stderr)

    def test_prompt_hook_records_confirmation(self):
        env = self.notion_env()
        del self.spec["paths"]["/boxes"]
        self.write_spec()
        fingerprint = json.loads(self.audit("inspect", env).stdout)["fingerprint"]
        result = self.submit_prompt(confirmation(fingerprint), env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("human confirmation recorded", result.stdout)
        self.assertEqual(self.audit("check", env).returncode, 0)

    def test_confirmation_without_digest_binds_the_current_change(self):
        env = self.notion_env()
        del self.spec["paths"]["/boxes"]
        self.write_spec()
        result = self.submit_prompt("maintainer confirmed: https://notion.so/" + "a" * 32, env)
        self.assertIn("human confirmation recorded", result.stdout)
        self.assertEqual(self.audit("check", env).returncode, 0)
        (self.root / "later.txt").write_text("changed after confirmation\n")
        self.assertIn("human confirmation required", self.audit("check", env).stderr)

    def test_prompt_hook_reports_failed_confirmation_without_blocking_the_prompt(self):
        env = self.notion_env()
        (self.root / "bin/curl").write_text("#!/bin/sh\nexit 22\n")
        del self.spec["paths"]["/boxes"]
        self.write_spec()
        fingerprint = json.loads(self.audit("inspect", env).stdout)["fingerprint"]
        result = self.submit_prompt(confirmation(fingerprint), env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("confirmation not recorded", result.stdout)
        self.assertIn("human confirmation required", self.audit("check", env).stderr)

    def test_unreadable_notion_cannot_approve(self):
        env = self.notion_env()
        (self.root / "bin/curl").write_text("#!/bin/sh\nexit 22\n")
        del self.spec["paths"]["/boxes"]
        self.write_spec()
        fingerprint = json.loads(self.audit("inspect", env).stdout)["fingerprint"]
        result = self.audit("record", env, {"hook_event_name": "UserPromptSubmit", "session_id": "human",
                            "prompt": confirmation(fingerprint)})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("human confirmation required", self.audit("check", env).stderr)

    def test_staged_contract_cannot_hide_behind_restored_working_copy(self):
        del self.spec["paths"]["/boxes"]
        self.write_spec()
        command(["git", "add", "openapi/box.openapi.yaml"], self.root, check=True)
        self.spec = specification()
        self.write_spec()
        self.assertNotEqual(self.audit("commit").returncode, 0)

    def test_shared_schema_addition_requires_cases_for_each_operation(self):
        self.optional_parameter()
        schema = self.spec["paths"]["/boxes"]["post"]["requestBody"]["content"]["application/json"]["schema"]
        self.spec["components"] = {"schemas": {"Create": schema}}
        content = self.spec["paths"]["/boxes"]["post"]["requestBody"]["content"]["application/json"]
        content["schema"] = {"$ref": "#/components/schemas/Create"}
        # The old version must already contain both operations sharing this schema.
        old = json.loads(command(["git", "show", "main:openapi/box.openapi.yaml"], self.root, check=True).stdout)
        old_schema = old["paths"]["/boxes"]["post"]["requestBody"]["content"]["application/json"]["schema"]
        old["components"] = {"schemas": {"Create": old_schema}}
        old["paths"]["/boxes"]["post"]["requestBody"]["content"]["application/json"]["schema"] = {"$ref": "#/components/schemas/Create"}
        old["paths"]["/copies"] = old["paths"]["/boxes"]
        current_spec = self.spec
        current_sdk = (self.root / "sdk.py").read_text()
        (self.root / "sdk.py").write_text(command(["git", "show", "main:sdk.py"], self.root, check=True).stdout)
        self.spec = old
        self.write_spec()
        command(["git", "add", "."], self.root, check=True)
        command(["git", "-c", "core.hooksPath=/dev/null", "commit", "-m", "shared schema"], self.root, check=True)
        command(["git", "branch", "-f", "main", "HEAD"], self.root, check=True)
        self.spec = current_spec
        self.spec["paths"]["/copies"] = self.spec["paths"]["/boxes"]
        self.write_spec()
        (self.root / "sdk.py").write_text(current_sdk)
        self.config["features"]["POST /copies body/extra"] = self.config["features"]["POST /boxes body/extra"]
        self.write_config()
        report = json.loads(self.audit("inspect").stdout)
        self.assertEqual(len(report["required"]), 8, report)

    def test_request_to_wrong_operation_does_not_satisfy_non_default_case(self):
        self.optional_parameter()
        sdk = self.root / "sdk.py"
        sdk.write_text(sdk.read_text().replace("url+'/boxes'", "url+('/wrong' if extra else '/boxes')"))
        self.assertIn("requested value missing", self.audit().stderr)

    def test_approval_accepts_existing_default_change(self):
        env = self.notion_env()
        schema = self.spec["paths"]["/boxes"]["post"]["requestBody"]["content"]["application/json"]["schema"]
        schema["properties"]["enabled"]["default"] = True
        self.write_spec()
        fingerprint = json.loads(self.audit("inspect", env).stdout)["fingerprint"]
        result = self.audit("record", env, {"hook_event_name": "UserPromptSubmit", "session_id": "human",
                           "prompt": confirmation(fingerprint)})
        self.assertEqual(result.returncode, 0, result.stderr)
        approved = self.audit("check", env)
        self.assertEqual(approved.returncode, 0, approved.stderr)

    def test_example_value_named_default_is_not_a_contract_default(self):
        self.spec["paths"]["/boxes"]["post"]["requestBody"]["content"]["application/json"]["example"] = {"default": False}
        self.write_spec()
        command(["git", "add", "."], self.root, check=True)
        command(["git", "-c", "core.hooksPath=/dev/null", "commit", "-m", "example"], self.root, check=True)
        command(["git", "branch", "-f", "main", "HEAD"], self.root, check=True)
        self.spec["paths"]["/boxes"]["post"]["requestBody"]["content"]["application/json"]["example"]["default"] = True
        self.write_spec()
        self.assertEqual(self.audit().returncode, 0)

    def test_receipt_without_all_required_cases_is_rejected(self):
        self.optional_parameter()
        self.assertEqual(self.audit().returncode, 0)
        path = self.root / ".git/api-compatibility.receipt.json"
        receipt = json.loads(path.read_text())
        receipt["passed"].pop()
        path.write_text(json.dumps(receipt))
        self.assertIn("missing or stale SDK cases", self.audit("check").stderr)

    def test_parameter_reordering_does_not_change_defaults(self):
        operation = self.spec["paths"]["/boxes"]["post"]
        operation["parameters"] = [{"name": name, "in": "query", "schema": {"type": "integer", "default": value}}
                                   for name, value in (("first", 1), ("second", 2))]
        self.write_spec()
        command(["git", "add", "."], self.root, check=True)
        command(["git", "-c", "core.hooksPath=/dev/null", "commit", "-m", "parameters"], self.root, check=True)
        command(["git", "branch", "-f", "main", "HEAD"], self.root, check=True)
        operation["parameters"].reverse()
        self.write_spec()
        result = self.audit()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_retargeted_reference_cannot_hide_default_change(self):
        self.spec["components"] = {"schemas": {"Off": {"type": "boolean", "default": False},
                                                 "On": {"type": "boolean", "default": True}}}
        properties = self.spec["paths"]["/boxes"]["post"]["requestBody"]["content"]["application/json"]["schema"]["properties"]
        properties["enabled"] = {"$ref": "#/components/schemas/Off"}
        self.write_spec()
        command(["git", "add", "."], self.root, check=True)
        command(["git", "-c", "core.hooksPath=/dev/null", "commit", "-m", "references"], self.root, check=True)
        command(["git", "branch", "-f", "main", "HEAD"], self.root, check=True)
        properties["enabled"] = {"$ref": "#/components/schemas/On"}
        self.write_spec()
        self.assertIn("existing default changes need human confirmation", self.audit().stderr)

    def assert_transport_cases(self, location, path_level=False):
        self.optional_parameter(nullable=False)
        operation = self.spec["paths"]["/boxes"]["post"]
        schema = operation["requestBody"]["content"]["application/json"]["schema"]["properties"].pop("extra")
        owner = self.spec["paths"]["/boxes"] if path_level else operation
        owner["parameters"] = [{"name": "extra", "in": location, "schema": schema}]
        self.write_spec()
        declaration = self.config["features"].pop("POST /boxes body/extra")
        self.config["features"][f"POST /boxes {location}/extra"] = declaration
        self.write_config()
        sdk = self.root / "sdk.py"
        text = sdk.read_text().replace("    if extra is not None and extra is not False: body['extra']=extra\n", "")
        if location == "query":
            text = text.replace("url+'/boxes'", "url+'/boxes'+('?extra=true' if extra else '')")
        else:
            text = text.replace("headers={'Content-Type':'application/json'}", "headers={'Content-Type':'application/json', **({'extra':'true'} if extra else {})}")
        sdk.write_text(text)
        result = self.audit()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_query_cases_capture_actual_transport(self):
        self.assert_transport_cases("query")

    def test_header_cases_capture_actual_transport(self):
        self.assert_transport_cases("header")

    def test_path_level_parameter_generates_operation_cases(self):
        self.assert_transport_cases("query", path_level=True)


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

    def test_other_api_ref_must_be_checked_out(self):
        base, head = self.commit_breaking_change()
        command(["git", "checkout", "main"], self.root, check=True)
        result = command(["bash", str(self.plugin / "scripts/api-compatibility.sh"), "push-ref", str(self.root), head, base], self.root)
        self.assertIn("check out and audit", result.stderr)

    def test_deleted_ref_needs_no_sdk_execution(self):
        base, _head = self.commit_breaking_change()
        result = command(["bash", str(self.plugin / "scripts/api-compatibility.sh"), "push-ref", str(self.root), "0" * 40, base], self.root)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_commit_audit_receipt_does_not_bypass_api_push_gate(self):
        base, head = self.commit_breaking_change()
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

    def test_push_rejects_staged_sources_that_are_not_in_head(self):
        self.optional_parameter()
        command(["git", "add", "."], self.root, check=True)
        self.assertIn("commit them before pushing", self.audit("push").stderr)

if __name__ == "__main__":
    unittest.main()
