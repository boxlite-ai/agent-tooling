"""Exercise the owned hook, actual subprocess channel, broker, and publication boundary."""
import importlib.util
import json
import os
from pathlib import Path
from unittest.mock import patch
import shutil
import subprocess
import tempfile
import signal
import sys
import time
import unittest

PLUGIN = Path(__file__).resolve().parents[2]


class OwnedWorker(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.plugin = self.root / "plugin"
        shutil.copytree(PLUGIN, self.plugin, ignore=shutil.ignore_patterns("__pycache__"))
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.git("init", "-q", "-b", "fixture")
        (self.repo / "source.txt").write_text("tracked evidence\n")
        (self.repo / "untracked-secret").write_text("private canary")
        self.git("add", "source.txt")
        self.git("-c", "core.hooksPath=/dev/null", "-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "fixture")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.doc = {"html_url": "https://github.com/example/project/issues/1",
                    "body": "## TL;DR\n\nProve assigned worker results.\n\n## Details\n\nRead the tracked source.\n\n"}
        (self.bin / "document.json").write_text(json.dumps(self.doc))
        (self.bin / "gh").write_text('#!/usr/bin/env python3\nfrom pathlib import Path\nprint(Path(__file__).with_name("document.json").read_text())\n')
        (self.bin / "gh").chmod(0o755)
        self.worker = self.bin / "worker"
        shutil.copyfile(PLUGIN / "tests/design/fixtures/owned-worker.py", self.worker)
        self.worker.chmod(0o755)
        policy = {"versions": {"codex": ["0.162.1"], "claude": ["2.1.322"]},
                  "models": {"codex": "fixture", "claude": "fixture"}, "offline_research": True,
                  "executables": {"codex": str(self.worker), "claude": str(self.worker),
                                  "curl": str(self.bin / "curl")}}
        (self.bin / "curl").write_text("#!/bin/sh\nexit 22\n")
        (self.bin / "curl").chmod(0o755)
        (self.plugin / ".agents/design-worker-policy.json").write_text(json.dumps(policy))
        self.env = {**os.environ, "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
                    "BOXLITE_HOOK_HOST": "codex", "PLUGIN_ROOT": str(self.plugin)}
        for key in ("GIT_DIR", "GIT_WORK_TREE", "CLAUDE_PROJECT_DIR", "CLAUDE_PLUGIN_ROOT"):
            self.env.pop(key, None)
        self.cli("register", self.doc["html_url"], check=True)

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.repo, check=True, capture_output=True).stdout

    def cli(self, *args, body=None, check=False):
        return subprocess.run(["bash", str(self.plugin / "scripts/design-doc.sh"), *args], cwd=self.repo,
                              env=self.env, input=body, capture_output=True, check=check, text=True)

    def hook(self, command=None, host="codex"):
        self.assertIsNone(command)
        return subprocess.run([sys.executable, "-I", str(self.plugin / "scripts/design-worker.py"), host, str(self.repo)],
                              cwd=self.repo,env=self.env,capture_output=True,text=True,timeout=45)

    def gate(self):
        payload = {"tool_name": "Edit", "cwd": str(self.repo), "session_id": "fixture",
                   "tool_input": {"file_path": "source.txt"}}
        return subprocess.run(["bash", str(self.plugin / ".agents/hooks/preflight-design-doc.sh")],
            input=json.dumps(payload), cwd=self.repo, env=self.env, capture_output=True, text=True)

    def record(self, kind):
        return json.loads((self.repo / ".git" / ("agent-tooling-design-" + kind + ".json")).read_text())

    def test_owned_roles_and_exact_snapshot(self):
        for host in ("codex", "claude"):
            with self.subTest(host=host):
                result = self.hook(host=host)
                diagnostics = self.repo / ".git/agent-tooling-design-worker-diagnostics.json"
                self.assertEqual(result.returncode, 0, result.stderr + (diagnostics.read_text() if diagnostics.exists() else ""))
                auditor = self.record("audit")
                self.assertEqual(auditor["verdict"], "PASS")
                self.assertEqual(auditor["worker_provenance"]["role"], "auditor")
                self.assertNotEqual(self.gate().returncode, 0)

                result = self.hook(host=host)
                self.assertEqual(result.returncode, 0, result.stderr)
                advisor = self.record("advice")
                self.assertEqual(advisor["worker_provenance"]["verdict_task_id"], auditor["worker_provenance"]["task_id"])
                self.assertEqual(self.gate().returncode, 0)


    def test_managed_cache_blocks_before_native_worker_starts(self):
        configuration = self.root / "claude-config"
        configuration.mkdir()
        policy_path = self.plugin / ".agents/design-worker-policy.json"
        policy = json.loads(policy_path.read_text())
        policy["authentication"] = {"CLAUDE_CONFIG_DIR":str(configuration)}
        policy_path.write_text(json.dumps(policy))
        for content in ('{"hooks":{"SessionStart":[]}}', 'invalid policy'):
            (configuration / "remote-settings.json").write_text(content)
            result = self.hook(host="claude")
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((self.bin / "observed").exists())
        (configuration / "remote-settings.json").write_text("{}")
        self.assertEqual(self.hook(host="claude").returncode, 0)

    def test_large_snapshot_publishes_both_roles(self):
        self.doc["body"] += "\n" + "Bounded source evidence. " * 400
        (self.bin / "document.json").write_text(json.dumps(self.doc))
        for _ in range(2):
            result = self.hook()
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.gate().returncode, 0)

    def test_failed_and_changed_results_cannot_publish(self):
        for mode in ("invalid", "wrong-digest", "wrong-role", "nonzero", "change-document", "oversized"):
            with self.subTest(mode=mode):
                (self.bin / "mode").write_text(mode)
                result = self.hook()
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertEqual((self.bin / "observed").read_text(), mode, result.stderr)
                self.assertNotEqual(self.gate().returncode, 0)

    def test_deadline_collection_preserves_owned_marker(self):
        self.env["DESIGN_AUDITOR_TIMEOUT"] = "1"
        (self.bin / "mode").write_text("late")
        result = self.hook()
        self.assertEqual(result.returncode, 0, result.stderr)
        outcome, assignment = self.record("audit"), self.record("worker")
        self.assertEqual(outcome["deadline_review"]["deadline"], assignment["review_deadline"])
        self.assertGreaterEqual(outcome["deadline_review"]["recorded_at"], assignment["review_deadline"])
        self.assertTrue(any(not item["allowed"] for item in self.record("worker-execution")["broker_calls"]))

    def test_replay_is_idempotent(self):
        result = self.hook()
        self.assertEqual(result.returncode, 0, result.stderr)
        state = self.record("audit")
        spec = importlib.util.spec_from_file_location("worker_runtime", self.plugin / "scripts/design-worker.py")
        runtime = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(runtime)
        previous = (self.repo / ".git/agent-tooling-design-audit.json").read_bytes()
        arguments = {"task_id": state["worker_provenance"]["task_id"], "proof": state["worker_provenance"],
                     "result": {key: state[key] for key in ("content_sha256", "verdict", "findings", "advisories")}}
        with patch.dict(os.environ, self.env, clear=True):
            runtime.bridge(self.repo, "publish", arguments)
            runtime.bridge(self.repo, "publish", arguments)
        self.assertEqual((self.repo / ".git/agent-tooling-design-audit.json").read_bytes(), previous)

    def test_interrupted_publication_reconciles_both_roles(self):
        spec = importlib.util.spec_from_file_location("worker_runtime", self.plugin / "scripts/design-worker.py")
        runtime = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(runtime)
        for kind in ("audit", "advice"):
            with self.subTest(kind=kind):
                (self.bin / "mode").write_text("pause")
                (self.bin / "ready").unlink(missing_ok=True)
                (self.bin / "release").unlink(missing_ok=True)
                payload = {"tool_name":"Bash","cwd":str(self.repo),"tool_input":{
                    "command":f'bash "{self.plugin}/scripts/design-doc.sh" run'}}
                child = subprocess.Popen([sys.executable,"-I",str(self.plugin / "scripts/design-worker.py"),"codex",str(self.repo)],
                    cwd=self.repo,env=self.env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
                child.stdin.close(); child.stdin = None
                try:
                    until = time.monotonic() + 10
                    while not (self.bin / "ready").exists() and child.poll() is None and time.monotonic() < until:
                        time.sleep(0.02)
                    self.assertTrue((self.bin / "ready").exists())
                    path = self.repo / ".git/agent-tooling-design-worker.json"
                    pending = path.read_bytes()
                    (self.bin / "release").write_text("release")
                    output, errors = child.communicate(timeout=10)
                    self.assertEqual(child.returncode, 0, output + errors)
                    state = self.record(kind)
                    committed = (self.repo / ".git" / ("agent-tooling-design-" + kind + ".json")).read_bytes()
                    # Both halves are actual production records at the two commit points.
                    path.write_bytes(pending)
                    fields = ("content_sha256", "verdict", "findings", "advisories") if kind == "audit" else ("content_sha256", "advice")
                    with patch.dict(os.environ, self.env, clear=True):
                        runtime.bridge(self.repo, "publish", {"task_id":state["worker_provenance"]["task_id"],
                            "proof":state["worker_provenance"], "result":{key:state[key] for key in fields}})
                    self.assertEqual(self.record("worker")["status"], "consumed")
                    self.assertEqual((self.repo / ".git" / ("agent-tooling-design-" + kind + ".json")).read_bytes(), committed)
                finally:
                    if child.poll() is None:
                        child.terminate()
                    if not child.stdout.closed:
                        child.communicate(timeout=10)

    def test_shared_log_change_and_concurrent_assignment_fail_closed(self):
        (self.bin / "mode").write_text("pause")
        payload = {"tool_name":"Bash","cwd":str(self.repo),"tool_input":{
            "command":f'bash "{self.plugin}/scripts/design-doc.sh" run'}}
        child = subprocess.Popen([sys.executable, "-I", str(self.plugin / "scripts/design-worker.py"), "codex", str(self.repo)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=self.repo, env=self.env, text=True)
        child.stdin.close(); child.stdin = None
        try:
            until = time.monotonic() + 10
            while not (self.bin / "ready").exists() and child.poll() is None and time.monotonic() < until:
                time.sleep(0.02)
            self.assertTrue((self.bin / "ready").exists())
            self.assertNotEqual(self.hook().returncode, 0)
            self.assertNotEqual(self.gate().returncode, 0)
            self.cli("log", body="Changed research record\n", check=True)
            (self.bin / "release").write_text("release")
            output, errors = child.communicate(timeout=10)
            self.assertNotEqual(child.returncode, 0, output + errors)
            self.assertNotEqual(self.gate().returncode, 0)
        finally:
            if child.poll() is None:
                child.terminate()
            if not child.stdout.closed:
                child.communicate(timeout=10)

    def accept_decision(self):
        spec = importlib.util.spec_from_file_location("worker_runtime", self.plugin / "scripts/design-worker.py")
        runtime = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(runtime)
        with patch.dict(os.environ, self.env, clear=True):
            snapshot = runtime.bridge(self.repo, "snapshot")
        current = snapshot["state"]
        # Use production state/hash and request/reply commands, including a real typed choice.
        hashed = subprocess.run(["bash", "-c", 'source "$1/.agents/lib/verdict-audit-state.sh"; '
            'source "$1/.agents/lib/design-doc.sh"; _design_doc_history_hash "$2"', "history",
            str(self.plugin), json.dumps(current)], capture_output=True, check=True, text=True).stdout.strip()
        state = self.repo / ".agents/state/design-decision-request.json"
        state.parent.mkdir(parents=True, exist_ok=True)
        binding = {key: snapshot[key] for key in ("root", "branch", "head", "url")}
        binding.update({"content_sha256":snapshot["snapshot"]["content_sha256"], "history_hash":hashed, "session":"fixture"})
        script = ["bash", str(self.plugin / "scripts/timed-user-prompt.sh")]
        request = subprocess.run([*script, "request", str(state), json.dumps({"binding":binding,
            "prefix":"design-decision:", "fallback":"keep-blocked"})],capture_output=True,check=True,text=True)
        identifier = json.loads(request.stdout)["id"]
        prompt = {"session_id":"fixture", "prompt":"design-decision: " + identifier + " Overrule fixture decision"}
        subprocess.run(["bash",str(self.plugin / ".agents/hooks/design-decision-prompt.sh")],
            cwd=self.repo,env={**self.env,"CLAUDE_PROJECT_DIR":str(self.repo)},input=json.dumps(prompt),
            text=True,capture_output=True,check=True)
        self.assertEqual(json.loads(state.read_text())["status"], "accepted")

    def test_stale_accepted_decision_cannot_block_changed_design(self):
        self.accept_decision()
        self.doc["body"] += "\nChanged design after the decision."
        (self.bin / "document.json").write_text(json.dumps(self.doc))
        result = self.hook()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.record("audit")["verdict"], "PASS")

    def test_accepted_current_decision_prevents_assignment(self):
        self.accept_decision()
        result = self.hook()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.bin / "observed").exists())

    @unittest.skipIf(os.name == "nt", "POSIX signal assertion; Windows requires native qualification")
    def test_cancellation_and_collection_timeout_reap_owned_processes(self):
        def alive(pid):
            try:
                os.kill(pid, 0)
                return True
            except ProcessLookupError:
                return False
        for cancel in (not getattr(self, "check_collection_timeout", False),):
            with self.subTest(cancel=cancel):
                (self.bin / "mode").write_text("hang")
                (self.bin / "ready").unlink(missing_ok=True)
                payload = {"tool_name":"Bash","cwd":str(self.repo),"tool_input":{
                    "command":f'bash "{self.plugin}/scripts/design-doc.sh" run'}}
                child = subprocess.Popen([sys.executable,"-I",str(self.plugin / "scripts/design-worker.py"),"codex",str(self.repo)],
                    cwd=self.repo,env={**self.env,"DESIGN_AUDITOR_TIMEOUT":"1"},stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
                child.stdin.close(); child.stdin = None
                try:
                    until = time.monotonic() + 10
                    while not (self.bin / "ready").exists() and child.poll() is None and time.monotonic() < until:
                        time.sleep(0.02)
                    self.assertTrue((self.bin / "ready").exists())
                    pids = [int((self.bin / name).read_text()) for name in ("worker.pid", "broker.pid")]
                    if cancel:
                        child.terminate()
                    output, errors = child.communicate(timeout=40)
                    self.assertNotEqual(child.returncode, 0, output + errors)
                    until = time.monotonic() + 6
                    while any(alive(pid) for pid in pids) and time.monotonic() < until:
                        time.sleep(0.05)
                    self.assertFalse(any(alive(pid) for pid in pids), str(pids))
                    self.assertNotEqual(self.gate().returncode, 0)
                finally:
                    if child.poll() is None:
                        child.terminate()
                    if not child.stdout.closed:
                        child.communicate(timeout=10)

    def test_collection_timeout_reaps_owned_processes(self):
        # Reuse the same boundary checks with a fresh fixture and no cancellation signal.
        self.check_collection_timeout = True
        self.test_cancellation_and_collection_timeout_reap_owned_processes()


class ProcessOwnership(unittest.TestCase):
    @unittest.skipIf(os.name == "nt", "POSIX pid_t conversion boundary")
    def test_posix_pid_boundaries_keep_registration_listener_alive(self):
        spec=importlib.util.spec_from_file_location("worker_process",PLUGIN/"scripts/design-worker-process.py")
        implementation=importlib.util.module_from_spec(spec);spec.loader.exec_module(implementation)
        import socket
        with tempfile.TemporaryDirectory() as temporary:
            owner=implementation.Owner(Path(temporary).resolve(),"fixture-nonce",sys.executable,shutil.which("bash"),
                                       PLUGIN/".agents/hooks/design-worker-group.sh")
            try:
                for pid in (-1,1,2147483647,2147483648,4294967295,4294967296):
                    with self.subTest(pid=pid),socket.create_connection(owner.address,timeout=2) as channel:
                        channel.sendall((json.dumps({"nonce":"fixture-nonce","pid":pid})+"\n").encode())
                        try:answer=channel.recv(16)
                        except TimeoutError:self.fail("invalid PID did not close its registration channel")
                        self.assertEqual(answer,b"")
                    self.assertTrue(owner.listener.is_alive(),"PID conversion terminated the listener")
                    self.assertFalse(owner.broker_registered.is_set())
            finally:owner.close()

    @unittest.skipIf(os.name == "nt", "POSIX controller startup failure")
    def test_failed_controller_startup_avoids_external_group_signal(self):
        spec=importlib.util.spec_from_file_location("worker_process",PLUGIN/"scripts/design-worker-process.py")
        implementation=importlib.util.module_from_spec(spec);spec.loader.exec_module(implementation)
        with tempfile.TemporaryDirectory() as temporary:
            directory=Path(temporary).resolve();group=directory/"failed-group.sh";group.write_text("exit 2\n")
            owner=implementation.Owner(directory,"fixture-nonce",sys.executable,shutil.which("bash"),group)
            child=owner.launch([sys.executable,"-c","pass"],dict(os.environ))
            try:
                child.communicate(timeout=10)
                self.assertEqual(child.returncode,2)
                with patch.object(implementation.os,"killpg",side_effect=PermissionError("numeric group identity is obsolete")):
                    try:owner.close()
                    except PermissionError:self.fail("startup cleanup signaled an unowned numeric group")
            finally:owner.close()

    def test_windows_job_configuration_failure_closes_created_handle(self):
        spec=importlib.util.spec_from_file_location("worker_process",PLUGIN/"scripts/design-worker-process.py")
        implementation=importlib.util.module_from_spec(spec);spec.loader.exec_module(implementation)
        from unittest.mock import Mock
        kernel=Mock();kernel.CreateJobObjectW.return_value=17;kernel.SetInformationJobObject.return_value=False
        with patch.object(implementation.ctypes,"WinDLL",return_value=kernel,create=True):
            with self.assertRaises(OSError):implementation.WindowsJob()
        kernel.CloseHandle.assert_called_once_with(17)

    @unittest.skipIf(os.name == "nt", "Injected Windows boundary; native qualification is separate")
    def test_rejected_windows_membership_preserves_registration_slot(self):
        spec=importlib.util.spec_from_file_location("worker_process",PLUGIN/"scripts/design-worker-process.py")
        implementation=importlib.util.module_from_spec(spec);spec.loader.exec_module(implementation)
        import socket
        from unittest.mock import Mock
        for failure in ("outside-job","create-job","assign-job"):
            with self.subTest(failure=failure),tempfile.TemporaryDirectory() as temporary:
                owner=implementation.Owner(Path(temporary).resolve(),"fixture-nonce",sys.executable,shutil.which("bash"),
                                           PLUGIN/".agents/hooks/design-worker-group.sh")
                boundary=Mock();boundary.member_handle.return_value=17
                nested=Mock();nested.kernel.AssignProcessToJobObject.return_value=False
                factory=Mock(return_value=nested)
                if failure=="outside-job":boundary.member_handle.side_effect=OSError("broker outside worker job")
                if failure=="create-job":factory.side_effect=OSError("job creation failed")
                owner.job=boundary
                accepted=None
                try:
                    with patch.object(implementation,"WindowsJob",factory),socket.create_connection(owner.address,timeout=2) as channel:
                        channel.sendall((json.dumps({"nonce":"fixture-nonce","pid":os.getpid()})+"\n").encode())
                        self.assertEqual(channel.recv(16),b"")
                    self.assertEqual(owner.channels,[],"rejected registration consumed the valid broker slot")
                    self.assertFalse(owner.broker_registered.is_set())
                    if failure!="outside-job":boundary.kernel.CloseHandle.assert_called_once_with(17)
                    if failure=="assign-job":nested.close.assert_called_once()
                    # Restore the injected backend, then exercise the shared slot with a real owned broker.
                    owner.job=None
                    program=owner.directory/"valid-broker.py"; ready=owner.directory/"valid-ready"
                    program.write_text("import pathlib,sys,time; pathlib.Path(sys.argv[1]).write_text('ready'); time.sleep(20)")
                    accepted=subprocess.Popen(owner.broker_command(program,ready),stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
                    until=time.monotonic()+5
                    while not ready.exists() and accepted.poll() is None and time.monotonic()<until:time.sleep(0.02)
                    self.assertTrue(ready.is_file(),"denied registration prevented a subsequent valid broker")
                    self.assertTrue(owner.broker_registered.is_set())
                finally:
                    owner.job=None;owner.close()
                    if accepted is not None:accepted.wait(timeout=3);accepted.stderr.close()

    @unittest.skipIf(os.name == "nt", "POSIX registration ownership boundary")
    def test_registration_rejects_malformed_and_wrong_identity(self):
        spec = importlib.util.spec_from_file_location("worker_process", PLUGIN / "scripts/design-worker-process.py")
        implementation = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(implementation)
        import socket
        with tempfile.TemporaryDirectory() as temporary:
            owner = implementation.Owner(Path(temporary).resolve(), "fixture-nonce", sys.executable,
                                         shutil.which("bash"), PLUGIN / ".agents/hooks/design-worker-group.sh")
            nonleader = subprocess.Popen([sys.executable,"-c","import time; time.sleep(20)"])
            try:
                self.assertNotEqual(os.getpgid(nonleader.pid), nonleader.pid)
                records = [None, True, 7, [{}], "record", {},
                           {"nonce":"wrong","pid":os.getpid()}, {"nonce":"fixture-nonce","pid":0},
                           {"nonce":"fixture-nonce","pid":True}, {"nonce":"fixture-nonce","pid":nonleader.pid}]
                packets = [(json.dumps(record)+"\n").encode() for record in records]
                packets += [b"x"*1025+b"\n", b"{invalid}\n"]
                for packet in packets:
                    with self.subTest(packet=packet[:80]), socket.create_connection(owner.address,timeout=2) as channel:
                        channel.sendall(packet)
                        try:
                            answer=channel.recv(16)
                        except ConnectionResetError:
                            answer=b""
                        except TimeoutError:
                            self.fail("malformed registration did not close its channel")
                        self.assertEqual(answer,b"")
                    self.assertTrue(owner.listener.is_alive(),"malformed registration killed the listener")
                    self.assertFalse(owner.broker_registered.is_set())
            finally:
                nonleader.kill(); nonleader.wait(timeout=3)
                owner.close()

    @unittest.skipIf(os.name == "nt", "POSIX registration ownership boundary")
    def test_registration_accepts_owned_broker_and_rejects_duplicate(self):
        spec = importlib.util.spec_from_file_location("worker_process", PLUGIN / "scripts/design-worker-process.py")
        implementation = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(implementation)
        import socket
        with tempfile.TemporaryDirectory() as temporary:
            directory=Path(temporary).resolve()
            program=directory/"broker.py"; payload=directory/"ready"
            program.write_text("import pathlib,sys,time; pathlib.Path(sys.argv[1]).write_text('ready'); time.sleep(20)")
            owner=implementation.Owner(directory,"fixture-nonce",sys.executable,shutil.which("bash"),
                                       PLUGIN/".agents/hooks/design-worker-group.sh")
            child=subprocess.Popen(owner.broker_command(program,payload),stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
            try:
                until=time.monotonic()+5
                while not payload.exists() and child.poll() is None and time.monotonic()<until:time.sleep(0.02)
                self.assertTrue(payload.is_file(),"valid broker did not reach its boundary")
                self.assertTrue(owner.broker_registered.is_set())
                with socket.create_connection(owner.address,timeout=2) as duplicate:
                    duplicate.sendall((json.dumps({"nonce":"fixture-nonce","pid":child.pid})+"\n").encode())
                    self.assertEqual(duplicate.recv(16),b"")
                self.assertIsNone(child.poll())
                self.assertEqual(sum(hasattr(channel,"shutdown") for channel in owner.channels),1)
            finally:
                owner.close(); child.wait(timeout=3); child.stderr.close()

    @unittest.skipIf(os.name == "nt", "POSIX controller owns group completion")
    def test_completed_controller_avoids_external_group_signal(self):
        spec = importlib.util.spec_from_file_location("worker_process", PLUGIN / "scripts/design-worker-process.py")
        implementation = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(implementation)
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary).resolve()
            owner = implementation.Owner(directory, "fixture-nonce", sys.executable, shutil.which("bash"),
                                         PLUGIN / ".agents/hooks/design-worker-group.sh")
            child = owner.launch([sys.executable, "-c", "pass"], dict(os.environ))
            try:
                child.communicate(timeout=10)
                self.assertEqual(child.returncode, 0)
                with patch.object(implementation.os, "killpg", side_effect=PermissionError("completed group cannot be signaled")):
                    try:
                        owner.close()
                    except PermissionError:
                        self.fail("cleanup signaled a completed external process group")
                self.assertTrue((directory / "worker-group/group-kill").is_file())
            finally:
                owner.close()

    @unittest.skipIf(os.name == "nt", "POSIX controller contract; Windows uses Job Objects")
    def test_broker_leader_death_reaps_probe_without_supervisor_eof(self):
        spec = importlib.util.spec_from_file_location("worker_process", PLUGIN / "scripts/design-worker-process.py")
        implementation = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(implementation)
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary).resolve()
            payload = directory / "probe.pid"
            program = directory / "broker.py"
            program.write_text("import pathlib,subprocess,sys,time\n"
                               "child=subprocess.Popen([sys.executable,'-c','import time; time.sleep(60)'])\n"
                               "pathlib.Path(sys.argv[1]).write_text(str(child.pid))\n"
                               "time.sleep(60)\n")
            owner = implementation.Owner(directory, "fixture-nonce", sys.executable, shutil.which("bash"),
                                         PLUGIN / ".agents/hooks/design-worker-group.sh")
            child = subprocess.Popen(owner.broker_command(program, payload), stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            try:
                until = time.monotonic() + 5
                while not payload.exists() and child.poll() is None and time.monotonic() < until:
                    time.sleep(0.02)
                self.assertTrue(payload.exists(), "broker never reached the probe boundary")
                probe_pid = int(payload.read_text())
                os.kill(child.pid, signal.SIGKILL)
                child.wait(timeout=3)
                until = time.monotonic() + 4
                while time.monotonic() < until:
                    status = subprocess.run(["ps", "-p", str(probe_pid), "-o", "stat="], capture_output=True).stdout.strip()
                    if not status or status.startswith(b"Z"):
                        break
                    time.sleep(0.05)
                self.assertTrue(not status or status.startswith(b"Z"), "probe survived its broker leader")
            finally:
                owner.close()
                child.wait(timeout=3)
                child.stderr.close()


if __name__ == "__main__":
    unittest.main()
