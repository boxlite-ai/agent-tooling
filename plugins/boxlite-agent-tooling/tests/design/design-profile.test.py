"""Check actual snapshot framing, pinned files, and generated host profiles."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
PLUGIN = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("profiles", PLUGIN / "scripts/design-worker.py")
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)
class Profiles(unittest.TestCase):
    def test_exact_snapshot_includes_trailing_newline(self):
        first=worker.snapshot({"body":"design", "log":"", "log_present":False})
        second=worker.snapshot({"body":"design\n", "log":"", "log_present":False})
        self.assertEqual(first["content_sha256"],hashlib.sha256(b"design").hexdigest())
        self.assertEqual(first["content_sha256"],second["content_sha256"])
        self.assertNotEqual(first["snapshot_sha256"],second["snapshot_sha256"])
        logged=worker.snapshot({"body":"design", "log":"", "log_present":True})
        self.assertNotEqual(first["content_sha256"],logged["content_sha256"])
        for body in ("a"*32001, "a\0b"):
            with self.assertRaises(ValueError): worker.snapshot({"body":body,"log":"","log_present":False})
    def test_pinned_inputs_are_regular_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);target=root/"input";target.write_bytes(b"source")
            self.assertEqual(worker.file_hash(target),hashlib.sha256(b"source").hexdigest())
            link=root/"link";link.symlink_to(target)
            with self.assertRaises(OSError): worker.file_hash(link)
            if os.name!="nt":
                fifo=root/"fifo";os.mkfifo(fifo)
                with self.assertRaises(ValueError):worker.file_hash(fifo)
    def test_restricted_host_profiles(self):
        policy={"models":{"codex":"fixture","claude":"fixture"}}
        for host in ("codex","claude"):
            with self.subTest(host=host),tempfile.TemporaryDirectory() as temporary:
                root=Path(temporary)
                argv=worker.command(host,"/fixture/cli",root,["python3","broker.py"],{"type":"object"},policy)
                if host=="claude":
                    self.assertEqual(argv[argv.index("--tools")+1],"")
                    self.assertIn("--strict-mcp-config",argv)
                    self.assertEqual(json.loads((root/"settings.json").read_text())["disableAllHooks"],True)
                else:
                    self.assertIn("--ignore-user-config",argv)
                    self.assertIn('web_search="disabled"',argv)
                    model=json.loads((root/"models.json").read_text())["models"][0]
                    self.assertEqual(model["shell_type"],"disabled")
                    self.assertIsNone(model["apply_patch_tool_type"])
if __name__ == "__main__": unittest.main()
