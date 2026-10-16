#!/usr/bin/env python3
"""Own the hook smoke's daemon group, including when bash cannot run its trap."""
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time


def main():
    # The hook has job control off. Survive teardown of its entire group,
    # not just PID-directed termination of the runner shell.
    os.setsid()
    parent_pid = int(sys.argv[1])
    run_dir = Path(sys.argv[2])
    stopping = False
    exiting = False
    daemon = None
    start_requested = False
    started = False

    def request_start(_signum, _frame):
        nonlocal start_requested
        start_requested = True

    def request_stop(signum, _frame):
        nonlocal stopping, exiting
        stopping = True
        if signum != signal.SIGUSR1:
            exiting = True

    for signum in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM, signal.SIGUSR1):
        signal.signal(signum, request_stop)
    signal.signal(signal.SIGUSR2, request_start)

    def stop_group(child):
        def send(signum):
            try:
                os.killpg(child.pid, signum)
                return True
            except ProcessLookupError:
                return False

        # A dedicated session keeps the hook, caller and resident app outside
        # the kill target. Escalate even if only a descendant ignores TERM.
        send(signal.SIGTERM)
        try:
            child.wait(timeout=1)
        except subprocess.TimeoutExpired:
            pass
        # Reap before probing/signalling again: Darwin can return EPERM for
        # killpg(..., 0) when the group contains only an unreaped dead child.
        send(signal.SIGKILL)
        child.wait()

    try:
        # The parent may already have died before Python installed handlers.
        if os.getppid() != parent_pid or exiting:
            return
        # Swift must not begin until detached cleanup ownership is established.
        (run_dir / "supervisor-ready").write_text(str(os.getpid()))
        while not exiting and os.getppid() == parent_pid:
            if start_requested and not started and not stopping:
                started = True
                daemon = subprocess.Popen(sys.argv[3:], start_new_session=True)
            if daemon is not None and (stopping or daemon.poll() is not None):
                stop_group(daemon)
                daemon = None
                (run_dir / "daemon-reaped").touch()
            elif stopping and not started:
                started = True
                (run_dir / "daemon-reaped").touch()
            time.sleep(0.05)
    finally:
        if daemon is not None:
            stop_group(daemon)
        # Bash owns normal EXIT cleanup. After SIGKILL/reparenting we own it.
        if os.getppid() != parent_pid and os.environ.get("VOICELAYER_RUN_TESTS_KEEP_RUN_DIR") != "1":
            shutil.rmtree(run_dir, ignore_errors=True)


if __name__ == "__main__":
    main()
