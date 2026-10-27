import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

from supervision import Supervisor


class SupervisionTests(unittest.TestCase):
    def test_later_phase_uses_remaining_budget_and_keeps_partial_log(self):
        with tempfile.TemporaryDirectory() as directory, Supervisor(0.6) as runner:
            path = Path(directory) / "phase.log"
            runner.run([sys.executable, "-c", "import time; time.sleep(0.3)"], path, 10)
            started = time.monotonic()
            with self.assertRaises(subprocess.TimeoutExpired):
                runner.run([sys.executable, "-u", "-c",
                            "import time; print('phase started'); time.sleep(30)"], path, 10)
            self.assertLess(time.monotonic() - started, 1)
            self.assertIn("phase started", path.read_text())

    def test_signal_to_outer_run_cleans_entire_child_group(self):
        for cancellation in (signal.SIGTERM, signal.SIGINT):
            with self.subTest(signal=cancellation), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "phase.log"
                child = "import os, time; print(os.getpid(), flush=True); time.sleep(30)"
                phase = ("import subprocess, sys, time; "
                         f"subprocess.Popen([sys.executable, '-u', '-c', {child!r}]); "
                         "print('phase started', flush=True); time.sleep(30)")
                script = ("import sys; from pathlib import Path; from supervision import Supervisor; "
                          f"\nwith Supervisor(30) as runner: runner.run([sys.executable, '-u', '-c', {phase!r}], Path({str(path)!r}), 30)")
                outer = subprocess.Popen(["timeout", "-k", "3", "30", sys.executable, "-B", "-c", script],
                                         cwd=Path(__file__).parent, env=os.environ, start_new_session=True,
                                         stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
                group = None
                try:
                    deadline = time.monotonic() + 5
                    while time.monotonic() < deadline:
                        lines = path.read_text().splitlines() if path.exists() else []
                        pids = [int(line) for line in lines if line.isdigit()]
                        if pids and "phase started" in lines:
                            group = os.getpgid(pids[0])
                            break
                        time.sleep(0.02)
                    self.assertIsNotNone(group, "phase did not stream its log before exit")
                    outer.send_signal(cancellation)
                    outer.wait(timeout=5)
                    self.assertIn(outer.returncode, (128 + cancellation, -cancellation), outer.stderr.read())
                    self.assertIn("phase started", path.read_text())
                    deadline = time.monotonic() + 3
                    while time.monotonic() < deadline:
                        processes = subprocess.check_output(["ps", "-axo", "pgid=,stat="], text=True)
                        alive = [line for line in processes.splitlines()
                                 if line.split()[0] == str(group) and not line.split()[1].startswith("Z")]
                        if not alive:
                            break
                        time.sleep(0.02)
                    self.assertFalse(alive, f"child group survived: {alive}")
                finally:
                    for pgid in (group, outer.pid):
                        if pgid:
                            try:
                                os.killpg(pgid, signal.SIGKILL)
                            except ProcessLookupError:
                                pass
                    outer.wait()
                    outer.stderr.close()


if __name__ == "__main__":
    unittest.main()
