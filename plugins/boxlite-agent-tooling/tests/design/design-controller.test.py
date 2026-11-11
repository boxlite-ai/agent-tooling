"""Exercise the existing controller API when its leader dies before supervisor EOF."""
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import unittest

PLUGIN = Path(__file__).resolve().parents[2]

class Controller(unittest.TestCase):
    @unittest.skipIf(os.name == "nt", "POSIX process-group controller")
    def test_leader_death_ends_group_before_supervisor_eof(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary).resolve()
            reader, writer = os.pipe()
            program = '''source "$1/.agents/lib/audit-process-group.sh" || exit 2
set +m
audit_group_process control "$2" 0 <&"$3" >/dev/null 2>&1 &
for ((attempt=0; attempt<150; attempt++)); do
  [[ ! -s "$2/group-ready" ]] || break
  sleep 0.02
done
[[ -s "$2/group-ready" ]] || exit 2
sleep 120 &
printf '%s\\n' "$!" > "$2/probe.pid"
wait
'''
            leader = subprocess.Popen(["bash", "-c", program, "controller-test", str(PLUGIN), str(directory), str(reader)],
                                      pass_fds=(reader,), start_new_session=True,
                                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            os.close(reader)
            try:
                until = time.monotonic()+5
                while not (directory/"probe.pid").exists() and leader.poll() is None and time.monotonic()<until:
                    time.sleep(0.02)
                self.assertTrue((directory/"probe.pid").is_file(), "controller did not reach the ready boundary")
                probe = int((directory/"probe.pid").read_text())
                os.kill(leader.pid, signal.SIGKILL)
                leader.wait(timeout=3)
                until = time.monotonic()+3
                status = b"live"
                while time.monotonic()<until:
                    status = subprocess.run(["ps","-p",str(probe),"-o","stat="],capture_output=True).stdout.strip()
                    if not status or status.startswith(b"Z"):break
                    time.sleep(0.05)
                self.assertTrue(not status or status.startswith(b"Z"), "probe survived leader death while supervisor remained open")
            finally:
                os.close(writer)
                if leader.poll() is None:leader.kill()
                leader.wait(timeout=3)

if __name__ == "__main__":unittest.main()
