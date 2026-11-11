"""Exercise the private group launcher through real descriptor and process boundaries."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

PLUGIN=Path(__file__).resolve().parents[2]

@unittest.skipIf(os.name=="nt","POSIX descriptor3 launcher; Windows uses Job Objects")
class GroupLauncher(unittest.TestCase):
    def test_supervisor_eof_terminates_launched_process(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory=Path(temporary).resolve();marker=directory/"worker.pid"
            reader,writer=os.pipe()
            bootstrap="import os,sys; fd=int(sys.argv[1]); os.dup2(fd,3,inheritable=True); os.execv(sys.argv[2],sys.argv[2:])"
            program="import os,pathlib,sys,time; pathlib.Path(sys.argv[1]).write_text(str(os.getpid())); time.sleep(120)"
            child=subprocess.Popen([sys.executable,"-I","-c",bootstrap,str(reader),shutil.which("bash"),
                                    str(PLUGIN/".agents/hooks/design-worker-group.sh"),str(directory),
                                    sys.executable,"-c",program,str(marker)],pass_fds=(reader,),start_new_session=True,
                                    stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
            os.close(reader)
            try:
                until=time.monotonic()+5
                while not marker.exists() and child.poll() is None and time.monotonic()<until:time.sleep(0.02)
                self.assertTrue(marker.is_file(),"launcher never executed the target after controller readiness")
                self.assertEqual(int(marker.read_text()),child.pid)
                os.close(writer);writer=None
                child.wait(timeout=5)
                self.assertNotEqual(child.returncode,0)
                until=time.monotonic()+3
                while not (directory/"group-kill").exists() and time.monotonic()<until:time.sleep(0.02)
                self.assertTrue((directory/"group-kill").is_file(),"in-group controller did not finish teardown")
            finally:
                if writer is not None:os.close(writer)
                if child.poll() is None:child.kill()
                child.communicate(timeout=5)

    def test_missing_lifetime_descriptor_refuses_target(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory=Path(temporary).resolve();marker=directory/"must-not-run"
            program="import pathlib,sys; pathlib.Path(sys.argv[1]).write_text('ran')"
            result=subprocess.run(["bash",str(PLUGIN/".agents/hooks/design-worker-group.sh"),str(directory),
                                   sys.executable,"-c",program,str(marker)],stdin=subprocess.DEVNULL,
                                   capture_output=True,start_new_session=True,timeout=5)
            self.assertNotEqual(result.returncode,0)
            self.assertFalse(marker.exists(),"target executed without an owned lifetime channel")

if __name__=="__main__":unittest.main()
