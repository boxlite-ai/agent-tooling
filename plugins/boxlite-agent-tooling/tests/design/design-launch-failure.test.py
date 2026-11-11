"""Check actual lifetime descriptors after an operating-system spawn failure."""
import importlib.util
import os
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch

PLUGIN=Path(__file__).resolve().parents[2]

class LaunchFailure(unittest.TestCase):
    @unittest.skipIf(os.name=="nt", "POSIX pipe startup boundary")
    def test_spawn_failure_closes_both_lifetime_descriptors(self):
        spec=importlib.util.spec_from_file_location("worker_process",PLUGIN/"scripts/design-worker-process.py")
        implementation=importlib.util.module_from_spec(spec);spec.loader.exec_module(implementation)
        descriptors=[];real_pipe=os.pipe
        def capture_pipe():
            pair=real_pipe();descriptors.extend(pair);return pair
        with tempfile.TemporaryDirectory() as temporary:
            directory=Path(temporary).resolve()
            owner=implementation.Owner(directory,"fixture-nonce",str(directory/"missing-python"),shutil.which("bash"),
                                       PLUGIN/".agents/hooks/design-worker-group.sh")
            try:
                with patch.object(implementation.os,"pipe",side_effect=capture_pipe):
                    with self.assertRaises(FileNotFoundError):owner.launch(["unused"],dict(os.environ))
                owner.close()
                leaked=[]
                for descriptor in descriptors:
                    try:os.fstat(descriptor);leaked.append(descriptor)
                    except OSError:pass
                self.assertEqual(leaked,[],"lifetime descriptors survived failed spawn and owner cleanup")
            finally:
                owner.close()
                for descriptor in descriptors:
                    try:os.close(descriptor)
                    except OSError:pass

if __name__=="__main__":unittest.main()
