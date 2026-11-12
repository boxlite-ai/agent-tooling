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
