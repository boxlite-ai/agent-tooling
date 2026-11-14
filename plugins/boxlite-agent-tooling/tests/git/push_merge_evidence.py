"""Exercise real Git objects, TLS, and pre-push; isolate installation/model services."""
import base64
import contextlib
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import json
import os
from pathlib import Path
import shutil
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

PLUGIN = Path(__file__).resolve().parents[2]


def execute(argv, cwd, env=None, data=None):
    result = subprocess.run(argv, cwd=cwd, env=env, input=data, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=30)
    if result.returncode:
        raise AssertionError(result.stderr.decode(errors="replace"))
    return result.stdout


class MergeEvidence(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="push-merge-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repo = self.root / "consumer"
        self.repo.mkdir()
        self.environment = {k: v for k, v in os.environ.items()
                            if not k.startswith(("GIT_", "CODEX_", "CLAUDE", "AGENT_", "BOXLITE_"))}
        self.environment.update(HOME=str(self.root), GIT_CONFIG_NOSYSTEM="1")
        self.git("init", "-q")
        self.git("config", "user.name", "fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        self.write("recipe.txt", "base recipe\n")
        self.write("identical.txt", "base entry\n")
        self.write("result-only.txt", "base entry\n")
        self.git("add", ".")
        self.git("commit", "-qm", "chore: establish fixture")
        self.base = self.oid("HEAD")
        self.git("checkout", "-qb", "feature")
        self.write("recipe.txt", "feature recipe\n")
        self.write("identical.txt", "same changed entry\n")
        self.git("add", ".")
        self.git("commit", "-qm", "feat: retain feature recipe")
        self.old = self.oid("HEAD")
        self.write("feature.txt", "ordinary unpublished change\n")
        self.git("add", ".")
        self.git("commit", "-qm", "feat: add unpublished change")
        self.first = self.oid("HEAD")
        self.git("checkout", "-qb", "main", self.base)
        self.write("recipe.txt", "published recipe\n")
        self.write("identical.txt", "same changed entry\n")
        self.write("published.txt", "".join(f"published-history-{i:06d} content\n" for i in range(14000)))
        self.git("add", ".")
        self.git("commit", "-qm", "chore: import published history")
        self.published = self.oid("HEAD")
        self.write("recipe.txt", "feature recipe\n")
        self.write("feature.txt", "ordinary unpublished change\n")
        self.write("result-only.txt", "merge-authored entry\n")
        self.git("add", ".")
        tree = self.git("write-tree").decode().strip()
        self.new = self.git("commit-tree", tree, "-p", self.first, "-p", self.published,
                            data=b"chore: merge published main\n").decode().strip()
        self.git("update-ref", "refs/heads/feature", self.new)
        self.git("checkout", "-q", "feature")
        self.git("remote", "add", "origin", "https://github.com/fixture/consumer.git")
        self.runtime = self.root / "plugin"
        shutil.copytree(PLUGIN, self.runtime, ignore=shutil.ignore_patterns("tests", "references", "__pycache__"))
        for name in ("verify-installation.sh", "sync-guidance.sh"):
            self.script(self.runtime / "scripts" / name, "#!/bin/sh\nexit 0\n")
        self.script(self.runtime / ".agents/hooks/preflight-commit-push.sh", """#!/bin/sh
cat >/dev/null
cp "$(git rev-parse --git-path codex-audit)/last-push-audit-context.diff" "$FIXTURE_EVIDENCE"
exit 0
""")
        (self.runtime / ".agents/lib/pr-watch-state.sh").unlink()
        self.evidence = self.root / "captured.diff"
        self.chained = self.root / "chained.stdin"
        self.script(self.repo / ".git/hooks/pre-push", '#!/bin/sh\ncat > "$FIXTURE_CHAINED"\n')
        helper = self.root / "credential-helper"
        self.script(helper, '#!/bin/sh\nprintf "username=fixture\\npassword=fixture-password\\n\\n"\n')
        self.git("config", "credential.helper", str(helper))
        self.ref_line = f"refs/heads/feature {self.new} refs/heads/feature {self.old}\n".encode()
        self.endpoint = (b"## ref-update " + self.ref_line +
                         self.git("log", "--format=commit-subject %H %s", self.old + ".." + self.new) +
                         self.git("diff", "--no-ext-diff", self.old, self.new))
        self.assertGreater(len(self.endpoint), 262144, "fixture must reach the original evidence overflow")
        self.advertised_main = self.published
        self.status = 200
        self.trust_certificate = True
        self.content_type = "application/x-git-receive-pack-advertisement"
        self.response_override = None
        self.requests = []
        self.start_tls()

    def git(self, *argv, data=None):
        return execute(["git", *argv], self.repo, self.environment, data)

    def oid(self, ref):
        return self.git("rev-parse", ref).decode().strip()

    def write(self, path, content):
        (self.repo / path).write_text(content)

    def script(self, path, content):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        path.chmod(0o755)

    def advertisement(self):
        def packet(data):
            return f"{len(data) + 4:04x}".encode() + data
        return (packet(b"# service=git-receive-pack\n") + b"0000" +
                packet(f"{self.old} refs/heads/feature\0report-status\n".encode()) +
                packet(f"{self.advertised_main} refs/heads/main\n".encode()) + b"0000")

    def start_tls(self):
        certificate, key = self.root / "cert.pem", self.root / "key.pem"
        execute(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                 "-subj", "/CN=github.com", "-addext", "subjectAltName=DNS:github.com",
                 "-keyout", str(key), "-out", str(certificate)], self.root)
        fixture = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                fixture.requests.append((self.path, self.headers.get("Authorization")))
                body = fixture.response_override if fixture.response_override is not None else fixture.advertisement()
                self.send_response(fixture.status)
                self.send_header("Content-Type", fixture.content_type)
                self.send_header("Content-Length", str(len(body)))
                if fixture.status == 302:
                    self.send_header("Location", "https://github.com/other/destination.git/info/refs?service=git-receive-pack")
                self.end_headers()
                with contextlib.suppress(BrokenPipeError, ConnectionResetError):
                    self.wfile.write(body)

            def log_message(self, *args):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(certificate, key)
        self.server.socket = context.wrap_socket(self.server.socket, server_side=True)
        thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(thread.join, 2)
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        self.bin = self.root / "bin"
        curl = shutil.which("curl")
        # Route production curl to real TLS without changing its URL or hostname verification.
        self.script(self.bin / "curl", f'''#!/bin/sh
exec '{curl}' -q "$@" --noproxy '*' --connect-to 'github.com:443:127.0.0.1:{self.server.server_port}' --cacert '{certificate}'
''')

    def run_hook(self, refs=None, url="https://github.com/fixture/consumer.git"):
        environment = dict(self.environment, PATH=str(self.bin) + os.pathsep + self.environment["PATH"],
                           AGENT_GATED="1", BOXLITE_PR_WATCH="0", FIXTURE_EVIDENCE=str(self.evidence),
                           FIXTURE_CHAINED=str(self.chained))
        for path in (self.evidence, self.chained):
            path.unlink(missing_ok=True)
        result = subprocess.run(["bash", str(self.runtime / ".githooks/pre-push"), "origin", url],
                                cwd=self.repo, env=environment, input=refs or self.ref_line,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=25)
        self.assertEqual(result.returncode, 0, result.stderr.decode(errors="replace"))
        return self.evidence.read_bytes()

    def test_published_merge_fits_and_keeps_decisions(self):
        evidence = self.run_hook()
        self.assertLessEqual(len(evidence), 262144,
                             "published main history must not exhaust reviewer evidence")
        self.assertIn(b"## ref-update " + self.ref_line.strip(), evidence)
        for term in (b"recipe.txt", b"identical.txt", b"result-only.txt", b"ordinary unpublished change"):
            self.assertIn(term, evidence)
        self.assertNotIn(b"published-history-000001 content", evidence)
        self.assertIn(hashlib.sha256(self.endpoint).hexdigest().encode(), evidence)
        self.assertEqual(self.chained.read_bytes(), self.ref_line)
        self.assertEqual(self.requests[0][0], "/fixture/consumer.git/info/refs?service=git-receive-pack")
        expected = "Basic " + base64.b64encode(b"fixture:fixture-password").decode()
        self.assertEqual(self.requests[0][1], expected)
        records = [json.loads(line.removeprefix(b"selected-entry ")) for line in evidence.splitlines()
                   if line.startswith(b"selected-entry ")]
        identical = next(item for item in records if item["path"] == "identical.txt")
        b, f, p, r = identical["base_first_second_result"]
        self.assertNotEqual(b, f)
        self.assertEqual(f, p)
        self.assertEqual(p, r)
        self.assertEqual(identical["reason"], "overlap")

    def amend_merge(self, path, content, *, published=True, subject="chore: extend published history", old_content=None):
        blob = self.git("hash-object", "-w", "--stdin", data=content).decode().strip()
        index = self.root / "private.index"

        def tree_at(commit, content_blob=blob):
            index.unlink(missing_ok=True)
            self.environment["GIT_INDEX_FILE"] = str(index)
            try:
                self.git("read-tree", commit)
                self.git("update-index", "--add", "--cacheinfo", "100644", content_blob, path)
                return self.git("write-tree").decode().strip()
            finally:
                self.environment.pop("GIT_INDEX_FILE", None)

        if old_content is not None:
            old_blob = self.git("hash-object", "-w", "--stdin", data=old_content).decode().strip()
            self.old = self.git("commit-tree", tree_at(self.old, old_blob), "-p", self.base,
                                data=b"feat: retain protocol source\n").decode().strip()
            self.first = self.git("commit-tree", tree_at(self.first, old_blob), "-p", self.old,
                                  data=b"feat: add unpublished change\n").decode().strip()
        if published:
            tree = tree_at(self.published)
            self.published = self.git("commit-tree", tree, "-p", self.published,
                                      data=(subject + "\n").encode()).decode().strip()
        tree = tree_at(self.new)
        self.new = self.git("commit-tree", tree, "-p", self.first, "-p", self.published,
                            data=b"chore: merge published main\n").decode().strip()
        self.advertised_main = self.published
        self.git("update-ref", "refs/heads/feature", self.new)
        self.ref_line = f"refs/heads/feature {self.new} refs/heads/feature {self.old}\n".encode()
        self.endpoint = (b"## ref-update " + self.ref_line +
                         self.git("log", "--format=commit-subject %H %s", self.old + ".." + self.new) +
                         self.git("diff", "--no-ext-diff", self.old, self.new))

    def test_receiving_denials_keep_exact_endpoint(self):
        original = self.advertisement()
        cases = ((302, self.content_type, original),
                 (200, "text/plain", original),
                 (200, self.content_type, original.replace(b"git-receive-pack", b"git-upload--pack")),
                 (200, self.content_type, original[:-1]),
                 (200, self.content_type, original.replace(self.old.encode(), self.base.encode(), 1)),
                 (200, self.content_type, b"x" * 262145))
        for status, content_type, response in cases:
            with self.subTest(status=status, content_type=content_type, bytes=len(response)):
                self.status, self.content_type, self.response_override = status, content_type, response
                before = len(self.requests)
                self.assertEqual(self.run_hook(), self.endpoint)
                self.assertEqual(len(self.requests), before + 1, "redirects must not be followed")
        self.status, self.content_type, self.response_override = 200, cases[0][1], None
        self.advertised_main = self.old
        self.assertEqual(self.run_hook(), self.endpoint, "unpublished ancestry cannot be excluded")

    def test_invalid_tls_keeps_endpoint(self):
        wrapper = self.bin / "curl"
        wrapper.write_text(wrapper.read_text().replace("--cacert '" + str(self.root / 'cert.pem') + "'", ""))
        self.assertEqual(self.run_hook(), self.endpoint)
        self.assertEqual(self.requests, [], "untrusted TLS must fail before HTTP")

    def test_custom_transport_and_unsupported_urls_keep_endpoint(self):
        for key, value in (("http.extraHeader", "X-Route: alternative"),
                           ("http.https://github.com/.version", "HTTP/1.1"),
                           ("url.https://elsewhere.invalid/.pushInsteadOf", "https://github.com/"),
                           ("remote.origin.receivepack", "custom-receive")):
            self.git("config", key, value)
            self.assertEqual(self.run_hook(), self.endpoint)
            self.git("config", "--unset-all", key)
        for url in ("git@github.com:fixture/consumer.git", "https://github.com/fixture/consumer.git?token=fixture",
                    "https://fixture@github.com/fixture/consumer.git"):
            self.assertEqual(self.run_hook(url=url), self.endpoint)
        self.assertEqual(self.requests, [])

    def test_plain_http_versions_preserve_value_boundaries(self):
        cases = [(('HTTP/1.1',), True), (('HTTP/2',), True),
                 (('HTTP/1.1', 'HTTP/2', 'HTTP/1.1'), True)]
        for invalid in ('', 'HTTP/3', 'HTTP/1.0', 'HTTP/1.1\nHTTP/2', ' HTTP/1.1'):
            cases.extend(((('HTTP/1.1', invalid), False), ((invalid, 'HTTP/1.1'), False)))
        for values, eligible in cases:
            with self.subTest(values=values):
                for value in values:
                    self.git('config', '--add', 'http.version', value)
                before = len(self.requests)
                try:
                    evidence = self.run_hook()
                    if eligible:
                        self.assertLessEqual(len(evidence), 262144)
                        self.assertIn(b'selected-entry', evidence)
                    else:
                        self.assertEqual(evidence, self.endpoint)
                    self.assertEqual(len(self.requests) - before, int(eligible))
                finally:
                    self.git('config', '--unset-all', 'http.version')

    def test_stock_git_exec_path_remains_eligible(self):
        helper = os.fsdecode(self.git('--exec-path').removesuffix(b'\n'))
        self.environment['GIT_EXEC_PATH'] = helper
        self.environment['PATH'] = os.pathsep.join((helper, helper + '/.', self.environment['PATH']))
        evidence = self.run_hook()
        self.assertLessEqual(len(evidence), 262144, 'stock Git exports must preserve scoped eligibility')
        self.assertIn(b'selected-entry', evidence)
        self.assertEqual(len(self.requests), 1)

    def test_unproved_helper_directory_cannot_launch_shadow_tools(self):
        helper = self.root / 'unproved-helpers'
        marker = self.root / 'shadow-tool-ran'
        for name in ('git', 'curl', 'bash'):
            self.script(helper / name, f'#!/bin/sh\nprintf "{name}\\n" >> "{marker}"\nexit 1\n')
        updates = self.root / 'updates'
        endpoint = self.root / 'endpoint'
        updates.write_bytes(self.ref_line)
        endpoint.write_bytes(self.endpoint)
        environment = dict(self.environment, GIT_EXEC_PATH=str(helper),
                           PATH=os.pathsep.join((str(helper), str(helper) + '/.', str(self.bin),
                                                self.environment['PATH'])))
        payload = '\0'.join((str(self.repo), 'origin', 'https://github.com/fixture/consumer.git',
                             str(updates), str(endpoint), '')).encode()
        result = subprocess.run([sys.executable, str(self.runtime / 'scripts/push-merge-evidence.py'), '--publish'],
                                cwd=self.repo, env=environment, input=payload,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=18)
        self.assertNotEqual(result.returncode, 0, 'custom helper directory must remain ineligible')
        self.assertEqual(endpoint.read_bytes(), self.endpoint)
        self.assertFalse(marker.exists(), 'the excluded directory must never supply executable tools')
        self.assertEqual(self.requests, [])

    def test_custom_or_ambiguous_git_exec_paths_keep_endpoint(self):
        helper = os.fsdecode(self.git('--exec-path').removesuffix(b'\n'))
        custom = self.root / 'custom-helpers'
        custom.mkdir()
        for value in ('', 'relative/helpers', str(custom), helper + '/.',
                      helper + os.pathsep + str(custom), helper + '\n'):
            with self.subTest(value=value):
                self.environment['GIT_EXEC_PATH'] = value
                self.assertEqual(self.run_hook(), self.endpoint)
        self.assertEqual(self.requests, [])

    def test_production_protocol_source_import_remains_eligible(self):
        self.amend_merge('published-protocol.py', (PLUGIN / 'scripts/push-merge-evidence.py').read_bytes())
        evidence = self.run_hook()
        self.assertLessEqual(len(evidence), 262144)
        self.assertIn(b'selected-entry', evidence)
        self.assertEqual(len(self.requests), 1)
        expected = 'Basic ' + base64.b64encode(b'fixture:fixture-password').decode()
        self.assertEqual(self.requests[0][1], expected)

    def test_protocol_source_upgrade_retains_complete_endpoint_checks(self):
        source = (PLUGIN / 'scripts/push-merge-evidence.py').read_bytes()
        prefix = b'header = "' + b'Authorization: '
        source = source.replace(prefix + b'Basic ', prefix)
        source = source.replace(b'authorization = base64.', b'authorization = b"Basic " + base64.')
        old_source = source.replace(b'authorization = b"Basic " + base64', b'authorization = base64')
        old_source = old_source.replace(prefix, prefix + b'Basic ')
        self.amend_merge('published-protocol.py', source, old_content=old_source)
        self.assertEqual(self.run_hook(), self.endpoint,
                         'removed protocol literals remain covered by complete endpoint checks')
        self.assertEqual(self.requests, [])

    def test_render_timeout_keeps_endpoint_and_cleans_descendants(self):
        child_path = self.root / 'renderer-descendant.pid'
        library = self.runtime / '.agents/lib/commit-push-evidence.sh'
        with library.open('a') as stream:
            stream.write(f'''\ncommit_push_render_evidence() {{
  sleep 20 &
  printf '%s' "$!" > '{child_path}'
  wait
}}
''')
        started = time.monotonic()
        evidence = self.run_hook()
        self.assertEqual(len(self.requests), 1, 'the receiving proof must finish before rendering blocks')
        self.assertTrue(child_path.exists(), 'the production path must reach the blocked renderer')
        self.assertEqual(evidence, self.endpoint, 'late rendering must not publish scoped evidence')
        self.assertLess(time.monotonic() - started, 18)
        state = subprocess.run(['ps', '-p', child_path.read_text(), '-o', 'stat='],
                               stdout=subprocess.PIPE, text=True).stdout.strip()
        self.assertTrue(not state or state.startswith('Z'), 'renderer descendant must not remain live')

    def test_unqualified_certificate_environment_keeps_endpoint(self):
        for key in ("CURL_CA_BUNDLE", "SSL_CERT_FILE", "SSL_CERT_DIR"):
            self.environment[key] = str(self.root / "cert.pem")
            self.assertEqual(self.run_hook(), self.endpoint)
            self.environment.pop(key)
        self.assertEqual(self.requests, [])

    def test_mixed_updates_preserve_both_headers_and_chained_input(self):
        other = self.ref_line.replace(b"refs/heads/feature", b"refs/heads/other")
        for refs in (self.ref_line + other, other + self.ref_line):
            evidence = self.run_hook(refs=refs)
            self.assertIn(b"## ref-update " + self.ref_line.strip(), evidence)
            self.assertIn(b"## ref-update " + other.strip(), evidence)
            self.assertIn(b"published-history-000001 content", evidence)
            self.assertEqual(self.chained.read_bytes(), refs)
        self.assertEqual(self.requests, [])

    def test_full_endpoint_checks_survive_narrowing(self):
        risks = (("published-secret.txt", ("gh" + "p_" + "x" * 25).encode(), "chore: extend published history"),
                 (".pr-reviewed.json", b"{}\n", "chore: extend published history"),
                 ("ordinary.txt", b"ordinary\n", "invalid subject"))
        initial = self.published, self.new, self.ref_line, self.endpoint
        for path, content, subject in risks:
            self.published, self.new, self.ref_line, self.endpoint = initial
            self.amend_merge(path, content, subject=subject)
            self.assertEqual(self.run_hook(), self.endpoint)
        self.assertEqual(self.requests, [], "endpoint findings precede optional proof")

    def test_literal_and_control_character_paths(self):
        paths = ("-option", ":(glob)*", "tab\tpath", "line\npath", "comma,name")
        for path in paths:
            self.amend_merge(path, b"merge-only edit\n", published=False)
        evidence = self.run_hook()
        records = [json.loads(line[len(b"selected-entry "):]) for line in evidence.splitlines()
                   if line.startswith(b"selected-entry ")]
        self.assertTrue(set(paths) <= {item["path"] for item in records})
        for path in paths:
            expected_blob = self.git("rev-parse", self.new + ":" + path).decode().strip()
            actual = next(item for item in records if item["path"] == path)
            self.assertEqual(actual["base_first_second_result"][3][2], expected_blob)

    def test_consumer_graph_and_diff_configuration_do_not_change_proof(self):
        grafts = self.repo / ".git/info/grafts"
        grafts.write_text(self.new + " " + self.base + "\n")
        self.git("replace", self.first, self.base)
        self.git("config", "diff.external", "must-not-run")
        self.git("config", "core.attributesFile", str(self.root / "attributes"))
        (self.root / "attributes").write_text("* diff=hostile\n")
        converter, calls = self.root / "converter", self.root / "conversion-calls"
        self.script(converter, f"#!/bin/sh\nprintf 'called\\n' >> '{calls}'\ncat \"$@\"\n")
        self.git("config", "diff.hostile.textconv", str(converter))
        self.git("diff", "--no-ext-diff", self.old, self.new)
        endpoint_calls = calls.read_bytes()
        calls.unlink()
        evidence = self.run_hook()
        self.assertLess(len(evidence), 262144)
        self.assertIn(b"selected-entry", evidence)
        self.assertEqual(calls.read_bytes(), endpoint_calls, "proof rendering must not invoke consumer text converters")

    def test_timeout_cleans_up_descendants_and_keeps_endpoint(self):
        child_path = self.root / "descendant.pid"
        self.script(self.bin / "curl", f"#!/bin/sh\nsleep 60 &\nprintf '%s' $! > '{child_path}'\nwait\n")
        started = time.monotonic()
        self.assertEqual(self.run_hook(), self.endpoint)
        self.assertLess(time.monotonic() - started, 18)
        pid = child_path.read_text()
        state = subprocess.run(["ps", "-p", pid, "-o", "stat="], stdout=subprocess.PIPE, text=True).stdout.strip()
        self.assertTrue(not state or state.startswith("Z"), "owned descendant must not remain live")

    def test_oversized_selected_artifact_keeps_exact_endpoint(self):
        self.amend_merge("result-large.txt", b"merge-only large content\n" * 14000, published=False)
        self.assertEqual(self.run_hook(), self.endpoint)

    def test_sanitized_artifact_budget_includes_redaction_and_context(self):
        self.amend_merge("result-assignments.txt", b"token=1\n" * 16000, published=False)
        self.assertEqual(self.run_hook(), self.endpoint)
        self.assertEqual(len(self.requests), 1, "proof ran; complete sanitized rendering exceeds its budget")

    def test_api_checks_finish_for_every_ref_before_proof(self):
        api = self.runtime / "scripts/api-compatibility.sh"
        original = api.with_name("api-original.sh")
        api.rename(original)
        log = self.root / "api.calls"
        self.script(api, f'#!/bin/sh\nprintf "%s\\n" "$1 $3 $4" >> "{log}"\nexec bash "{original}" "$@"\n')
        refs = self.ref_line + self.ref_line.replace(b"refs/heads/feature", b"refs/heads/other")
        self.run_hook(refs=refs)
        self.assertEqual(log.read_text().splitlines(), [f"push-ref {self.new} {self.old}"] * 2)

    def test_tree_staging_aggregate_boundary(self):
        spec = importlib.util.spec_from_file_location("push_proof", PLUGIN / "scripts/push-merge-evidence.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        oids = (self.base, self.first, self.published, self.new)
        expected = sum(len(self.git("ls-tree", "-rz", "--full-tree", oid)) for oid in oids)

        def reader(*args, maximum):
            return module.execute(["git", "-C", str(self.repo), *args], self.environment,
                                  time.monotonic() + 5, maximum)

        with patch.object(module, "TREE_LIMIT", expected):
            trees = module.read_trees(reader, oids)
            self.assertEqual(trees[3][b"recipe.txt"][2], self.git("rev-parse", self.new + ":recipe.txt").decode().strip())
        with patch.object(module, "TREE_LIMIT", expected - 1):
            with self.assertRaises(ValueError):
                module.read_trees(reader, oids)


class SelectionBoundaries(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location("push_proof", PLUGIN / "scripts/push-merge-evidence.py")
        cls.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.module)

    def test_selection_truth_table(self):
        base = ["100644", "blob", "a" * 40]
        changed = ["100644", "blob", "b" * 40]
        mode = ["100755", "blob", "a" * 40]
        cases = ((base, base, base, base, False), (base, base, base, changed, True),
                 (base, changed, base, changed, False), (base, changed, base, base, True),
                 (base, changed, changed, changed, True), (base, None, None, None, True),
                 (base, mode, base, mode, False), (base, mode, base, base, True),
                 (None, changed, changed, changed, True), (None, changed, None, changed, False))
        for b, f, p, r, expected in cases:
            trees = [{b"path": entry} if entry else {} for entry in (b, f, p, r)]
            self.assertEqual(bool(list(self.module.select_entries(*trees))), expected, (b, f, p, r))

    def test_stream_exact_limit_and_overflow(self):
        command = [sys.executable, "-c", "import sys;sys.stdout.buffer.write(b'x'*int(sys.argv[1]))", "4096"]
        self.assertEqual(len(self.module.execute(command, dict(os.environ), time.monotonic() + 5, 4096)), 4096)
        command[-1] = "4097"
        with self.assertRaises(ValueError):
            self.module.execute(command, dict(os.environ), time.monotonic() + 5, 4096)


if __name__ == "__main__":
    unittest.main()
