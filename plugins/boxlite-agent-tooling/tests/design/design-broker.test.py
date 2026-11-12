"""Allowed/denied checks at source and public-transport boundaries."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

PLUGIN = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("broker", PLUGIN / "scripts/design-worker-broker.py")
broker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(broker)


class SourceBoundary(unittest.TestCase):
    def test_snapshot_discovery_history_and_denied_paths(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            repo, cache = root / "repo", root / "cache"
            repo.mkdir(); cache.mkdir()

            def git(*arguments):
                return subprocess.run(["git", "-c", "core.hooksPath=/dev/null", *arguments], cwd=repo,
                                      check=True, capture_output=True).stdout.decode().strip()

            git("init", "-q")
            (repo / "source.txt").write_text("first tracked version\n")
            git("add", "source.txt")
            git("-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "first")
            first = git("rev-parse", "HEAD")
            (repo / "source.txt").write_text("second committed version\n")
            git("add", "source.txt")
            git("-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "second")
            second = git("rev-parse", "HEAD")
            (repo / "source.txt").write_text("current unstaged version\n")
            (repo / "untracked-secret").write_text("private fixture canary")
            if os.name != "nt":
                (repo / "link").symlink_to(root / "outside-secret")
                git("add", "link")
            source = broker.sources(repo, cache, shutil.which("git"))
            data = {"sources": source, "research": [], "cutoff": time.monotonic() + 10}
            self.assertIn("source.txt", broker.call(data, "source_list", {"prefix": ""}))
            self.assertNotIn("untracked-secret", source["files"])
            self.assertNotIn("link", source["files"])
            self.assertEqual(broker.call(data, "source_read", {"path": "source.txt", "version": "current"}), "current unstaged version\n")
            self.assertEqual(broker.call(data, "source_read", {"path": "source.txt", "version": "base"}), "second committed version\n")
            self.assertEqual(broker.call(data, "source_search", {"query": "unstaged"})[0]["path"], "source.txt")
            # Poison repository-local history after capture; the broker uses clean metadata.
            (repo / ".git/info/grafts").write_text(second + "\n")
            history = broker.call(data, "source_history", {"path": "source.txt", "limit": 10})
            self.assertIn(first, history)
            for path in ("untracked-secret", "link", "../outside-secret", ".git/config"):
                with self.subTest(path=path), self.assertRaises(ValueError):
                    broker.call(data, "source_read", {"path": path, "version": "current"})
            with self.assertRaises(ValueError):
                broker.call(data, "source_history", {"path": "source.txt", "limit": 11})
            # Validly typed private payloads cannot create a new outbound operation.
            with patch.object(broker, "public_fetch") as transport:
                for name, arguments in (("research_search", {"query": "private fixture canary"}),
                                        ("research_read", {"id": 0, "url": "https://example.com/private-fixture-canary"})):
                    with self.assertRaises(ValueError):
                        broker.call(data, name, arguments)
                transport.assert_not_called()


@unittest.skipIf(os.name == "nt", "POSIX executable transport fixture; native Windows transport remains a qualification target")
class TransportBoundary(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.log = self.root / "transport.json"
        self.curl = self.root / "curl"
        self.curl.write_text("#!/usr/bin/python3\nimport json,os,sys\nfrom pathlib import Path\n"
            f"Path({str(self.log)!r}).write_text(json.dumps({{'args':sys.argv[1:],'env':dict(os.environ)}}))\n"
            "print('public fixture evidence')\nprint('8.8.8.8 200',file=sys.stderr)\n")
        self.curl.chmod(0o755)

    def fetch(self, peers, url="https://example.com/evidence", identifiers=()):
        answers = [(socket.AF_INET, socket.SOCK_STREAM, 6, "", (peer, 443)) for peer in peers]
        with patch.object(broker.socket, "getaddrinfo", return_value=answers):
            return broker.public_fetch(url, str(self.curl), identifiers)

    def test_allowed_transport_pins_peer_and_strips_credentials(self):
        with patch.dict(os.environ, {"HTTPS_PROXY": "http://private-proxy.invalid", "ANTHROPIC_API_KEY": "private-fixture-key"}):
            self.assertIn("public fixture evidence", self.fetch(["8.8.8.8"], "https://example.com/evidence%20name"))
        observed = json.loads(self.log.read_text())
        self.assertEqual(observed["args"][0], "--disable")
        self.assertIn("example.com:443:8.8.8.8", observed["args"])
        self.assertNotIn("HTTPS_PROXY", observed["env"])
        self.assertNotIn("ANTHROPIC_API_KEY", observed["env"])

    def test_unsafe_dns_and_encoded_identifiers_never_reach_transport(self):
        for peers in (["127.0.0.1"], ["8.8.8.8", "169.254.169.254"], ["224.0.0.1"], []):
            with self.subTest(peers=peers), self.assertRaises(ValueError):
                self.fetch(peers)
        for url in ("https://user:password@example.com/", "https://example.com/?email=fixture%40example.invalid",
                    "https://example.com/%2570rivate-canary", "https://example.com/%25252570rivate-canary",
                    "http://example.com/", "https://example.com/%0aheader", "https://example.com/%2525250aheader"):
            with self.subTest(url=url), self.assertRaises(ValueError):
                self.fetch(["8.8.8.8"], url, ["private-canary"])
        self.assertFalse(self.log.exists())

    def test_redirect_status_and_streamed_overflow_fail(self):
        self.curl.write_text(self.curl.read_text().replace("8.8.8.8 200", "8.8.8.8 302"))
        with self.assertRaises(ValueError):
            self.fetch(["8.8.8.8"])
        self.curl.write_text("#!/usr/bin/python3\nimport sys\nsys.stdout.write('x'*1048576)\n")
        with self.assertRaisesRegex(ValueError, "output exceeds"):
            self.fetch(["8.8.8.8"])


if __name__ == "__main__":
    unittest.main()
