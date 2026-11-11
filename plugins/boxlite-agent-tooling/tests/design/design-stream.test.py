"""Exercise bounded collection with real subprocess pipes."""
import importlib.util
from pathlib import Path
import subprocess
import sys
import time
import unittest
PLUGIN = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("collector", PLUGIN / "scripts/design-worker.py")
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)

class Streams(unittest.TestCase):
    def collect(self, program, task=b"task", interval=5, alive=True):
        child = subprocess.Popen([sys.executable, "-c", program], stdin=subprocess.PIPE,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.addCleanup(lambda: child.poll() is None and child.kill())
        class Owner:
            def parent_alive(self): return alive
            def close(self):
                if child.poll() is None: child.kill()
                child.wait(timeout=3)
        owner = Owner()
        try:
            return worker.collect(child, task, time.monotonic()+interval, owner)
        finally:
            owner.close()
            for pipe in (child.stdin, child.stdout, child.stderr):
                if not pipe.closed: pipe.close()
    def test_duplex_channels(self):
        result = self.collect("import sys; sys.stdout.buffer.write(sys.stdin.buffer.read()); sys.stderr.write('diagnostic')")
        self.assertEqual(result, (b"task", b"diagnostic"))
    def test_output_limit_on_each_channel(self):
        for channel in ("stdout", "stderr"):
            with self.subTest(channel=channel), self.assertRaises(ValueError):
                self.collect("import sys; sys.stdin.buffer.read(); sys."+channel+".buffer.write(b'x'*1048577)")
    def test_deadline_and_parent_loss(self):
        for interval,alive,error in ((0.05,True,ValueError),(5,False,InterruptedError)):
            with self.subTest(alive=alive), self.assertRaises(error):
                self.collect("import time; time.sleep(10)", interval=interval, alive=alive)
    def test_input_failure_is_rejected(self):
        with self.assertRaises(ValueError):
            self.collect("import os; os.close(0)", task=b"x"*1048576)
if __name__ == "__main__": unittest.main()
