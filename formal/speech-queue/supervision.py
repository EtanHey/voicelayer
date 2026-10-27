import os
import signal
import subprocess
import time


class Supervisor:
    def __init__(self, seconds):
        self.deadline = time.monotonic() + seconds
        self.handlers = {}
        self.child = None

    def __enter__(self):
        for sig in (signal.SIGTERM, signal.SIGINT):
            self.handlers[sig] = signal.signal(sig, self.cancel)
        return self

    def __exit__(self, *_):
        for sig, handler in self.handlers.items():
            signal.signal(sig, handler)

    def cancel(self, sig, _frame):
        if self.child is not None:
            self.signal_group(self.child, sig)
        raise SystemExit(128 + sig)

    @staticmethod
    def signal_group(child, sig):
        try:
            os.killpg(child.pid, sig)
        except ProcessLookupError:
            pass
        except PermissionError:
            if subprocess.run(["pgrep", "-g", str(child.pid)], stdout=subprocess.DEVNULL,
                              env=os.environ).returncode != 1:
                raise

    def run(self, command, log, seconds, **kwargs):
        remaining = min(seconds, self.deadline - time.monotonic())
        if remaining <= 0:
            raise subprocess.TimeoutExpired(command, remaining)
        with log.open("wb", buffering=0) as output:
            child = subprocess.Popen(command, stdout=output, stderr=subprocess.STDOUT,
                                     start_new_session=True, **kwargs)
            self.child = child
            try:
                return child.wait(timeout=remaining)
            finally:
                self.signal_group(child, signal.SIGKILL)
                child.wait()
                self.child = None
