"""Check generated CLI schemas and the real recorder's input validation."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

PLUGIN = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("design_worker", PLUGIN / "scripts/design-worker.py")
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)


class DesignResults(unittest.TestCase):
    def record(self, field, items):
        role = "advisor" if field == "advice" else "auditor"
        result = {"content_sha256": "a" * 64}
        if role == "auditor":
            result.update(verdict="FAIL" if field == "findings" and items else "PASS",
                          findings=[], advisories=[])
        result[field] = items
        script = '''source "$1/.agents/lib/design-doc.sh"
design_doc_binding() { printf '%s\\n' "$3"; }
if [[ "$2" == auditor ]]; then design_doc_audit_record /fixture
else design_doc_advice_record /fixture; fi'''
        completed = subprocess.run(["bash", "-c", script, "fixture", str(PLUGIN), role],
                                   input=json.dumps(result), text=True, capture_output=True)
        return result, completed

    def test_cli_schemas_describe_and_enforce_supported_limits(self):
        policy = {"models": {"codex": "fixture", "claude": "fixture"}}
        for host in ("codex", "claude"):
            for role, fields in (("auditor", ("findings", "advisories")), ("advisor", ("advice",))):
                with self.subTest(host=host, role=role), tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary)
                    argv = worker.command(host, "/fixture/cli", root, ["python3", "broker.py"],
                                          worker.result_schema(role), policy)
                    schema = (json.loads(argv[argv.index("--json-schema") + 1]) if host == "claude"
                              else json.loads((root / "schema.json").read_text()))
                    for field in fields:
                        value = schema["properties"][field]
                        limit = 5 if field == "advice" else 50
                        self.assertIn(str(limit), value.get("description", ""))
                        self.assertIn("500", value["items"].get("description", ""))
                        self.assertIn("pattern", value["items"])
                        if host == "codex":
                            self.assertEqual(value.get("maxItems"), limit)
                            self.assertEqual(value["items"].get("minLength"), 1)
                            self.assertEqual(value["items"].get("maxLength"), 500)
                        else:
                            self.assertNotIn("maxItems", value)
                            self.assertNotIn("minLength", value["items"])
                            self.assertNotIn("maxLength", value["items"])

    def test_valid_boundaries_preserve_content(self):
        for field, maximum in (("findings", 50), ("advisories", 50), ("advice", 5)):
            for items in ([], ["x"], ["x" * 500], ["界" * 500], ["x"] * maximum):
                with self.subTest(field=field, size=len(items)):
                    original, result = self.record(field, items)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(json.loads(result.stdout), original)

    def test_invalid_boundaries_identify_field_and_limit(self):
        for field, maximum in (("findings", 50), ("advisories", 50), ("advice", 5)):
            cases = (([""], f"{field}[0]: length 0 is below minimum 1 characters"),
                     (["x" * 501], f"{field}[0]: length 501 exceeds maximum 500 characters"),
                     (["x"] * (maximum + 1), f"{field}: item count {maximum + 1} exceeds maximum {maximum}"),
                     ([1], f"{field}[0]: expected a string"),
                     ("x", f"{field}: expected an array"))
            cases += tuple((["x" + control], f"{field}[0]: control characters are forbidden")
                           for control in ("\n", "\t", "\0", "\x1f", "\x7f", "\x85", "\x9f"))
            for items, diagnostic in cases:
                with self.subTest(field=field, diagnostic=diagnostic):
                    _, result = self.record(field, items)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(result.stdout, "")
                    self.assertIn(diagnostic, result.stderr)


if __name__ == "__main__":
    unittest.main()
