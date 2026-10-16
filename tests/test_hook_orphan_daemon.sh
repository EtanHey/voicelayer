#!/usr/bin/env bash
# Exercise the actual hook runner with cheap Swift/Bun-suite shims, no live audio.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 - "$ROOT" <<'PY'
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time

root = Path(sys.argv[1])
base = Path(tempfile.mkdtemp(prefix="vlho-", dir="/tmp"))
bin_dir = base / "bin"
bin_dir.mkdir()
real_bun = shutil.which("bun")

def executable(name, body):
    path = bin_dir / name
    path.write_text(body)
    path.chmod(0o755)

executable("swift", "#!" + sys.executable + "\n" + '''
import os, pathlib, sys, time
case = os.environ["HOOK_CASE"]
if case in ("KILL-swift-build", "KILL-group-swift-build", "KILL-swift-test"):
    phase = "test" if case == "KILL-swift-test" else "build"
    if sys.argv[1] == phase:
        pathlib.Path(os.environ["HOOK_RECORD"] + ".swift").write_text(str(os.getpid()))
        time.sleep(60)
''')
executable("plutil", "#!/bin/sh\nexit 0\n")
executable("bun", "#!" + sys.executable + "\n" + '''
import os, pathlib, signal, socket, subprocess, sys, time
if sys.argv[1] == "test":
    if os.environ["HOOK_CASE"] == "KILL-late":
        pathlib.Path(os.environ["HOOK_RECORD"] + ".suite").write_text(str(os.getpid()))
        time.sleep(10)
    raise SystemExit(0)
case = os.environ["HOOK_CASE"]
run_dir = os.environ["VOICELAYER_TMP_ROOT"]
record = pathlib.Path(os.environ["HOOK_RECORD"])
if case == "real":
    record.write_text(str(os.getpid()))
    os.execv(os.environ["HOOK_REAL_BUN"], [os.environ["HOOK_REAL_BUN"], *sys.argv[1:]])
if case == "stubborn":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    child = subprocess.Popen([sys.executable, "-c",
        "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)", run_dir])
    record.write_text(f"{os.getpid()} {child.pid}")
else:
    record.write_text(str(os.getpid()))
if case == "failure":
    raise SystemExit(7)
if case in ("success", "debug", "stubborn", "suite-failure", "KILL-late"):
    sock = socket.socket(socket.AF_UNIX)
    sock.bind(os.environ["VOICELAYER_MCP_SOCKET_PATH"])
while True:
    time.sleep(0.05)
''')

def wait_until(predicate, seconds=8):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        if predicate():
            return True
        time.sleep(0.05)
    return False

def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False

failures = []
try:
    def interrupted(signum, _frame):
        raise SystemExit(128 + signum)
    for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(signum, interrupted)
    cases = ("KILL-group", "KILL-swift-build", "KILL-group-swift-build", "KILL-swift-test",
             "success", "failure", "timeout", "INT", "TERM", "HUP", "KILL", "KILL-late", "stubborn", "debug", "suite-failure", "real")
    for case in cases:
        lane = base / case
        lane.mkdir()
        record = lane / "pids"
        env = dict(os.environ, PATH=str(bin_dir) + ":" + os.environ["PATH"], TMPDIR=str(lane),
                   HOOK_CASE=case, HOOK_RECORD=str(record), HOOK_REAL_BUN=real_bun)
        env["VOICELAYER_RUN_TESTS_KEEP_RUN_DIR"] = "1" if case == "debug" else "0"
        for kind in ("SWIFT", "BUN"):
            env[f"VOICELAYER_RUN_TESTS_FORCE_{kind}_FAIL"] = "1" if case == "suite-failure" else "0"
        runner = None
        pids = []
        daemon_group = None
        with (lane / "output").open("w+") as output:
            try:
                runner = subprocess.Popen(["bash", str(root / "scripts/run_tests.sh")], env=env,
                                          stdout=output, stderr=output, start_new_session=True)
                run_dir = lane / f"voicelayer-run-tests.{runner.pid}"
                if "swift" in case:
                    swift_record = Path(str(record) + ".swift")
                    assert wait_until(lambda: swift_record.exists() and swift_record.stat().st_size > 0), "Swift never started"
                    pids = [int(swift_record.read_text())]
                    assert run_dir.exists() and not record.exists(), "early test must precede daemon start"
                else:
                    assert wait_until(lambda: record.exists() and record.stat().st_size > 0), "daemon never started"
                    pids = [int(p) for p in record.read_text().split()]
                if case == "KILL-group":
                    daemon_group = os.getpgid(pids[0])
                    assert daemon_group != runner.pid, "daemon shares caller group"
                if "group" in case:
                    # runner is our new session/group leader; never signal the caller's group.
                    assert os.getpgid(runner.pid) == runner.pid
                    os.killpg(runner.pid, signal.SIGKILL)
                elif "swift" in case:
                    os.kill(runner.pid, signal.SIGKILL)
                elif case in ("INT", "TERM", "HUP", "KILL"):
                    os.kill(runner.pid, getattr(signal, "SIG" + case))
                if case == "KILL-late":
                    assert wait_until(lambda: Path(str(record) + ".suite").exists()), "suite never started"
                    os.kill(runner.pid, signal.SIGKILL)
                status = runner.wait(timeout=22)
                expected = {"failure": 1, "timeout": 1, "suite-failure": 1, "INT": 130, "TERM": 143,
                            "HUP": 129, "KILL": -9, "KILL-late": -9}.get(case, 0)
                if case.startswith("KILL"):
                    expected = -9
                assert status == expected, f"exit {status}, expected {expected}"
                daemon_pids = [] if "swift" in case else pids
                assert wait_until(lambda: all(not alive(p) for p in daemon_pids)), f"surviving daemon/descendants: {daemon_pids}"
                if daemon_group is not None:
                    def group_gone():
                        try:
                            os.killpg(daemon_group, 0)
                            return False
                        except ProcessLookupError:
                            return True
                        except PermissionError:
                            return False
                    assert wait_until(group_gone), "daemon process group remains"
                assert wait_until(lambda: run_dir.exists() == (case == "debug")), "RUN_DIR retention incorrect"
                # Supervisor and any descendants bearing the run identity must also be gone.
                processes = subprocess.check_output(["ps", "-ax", "-o", "pid=,command="], text=True)
                assert str(run_dir) not in processes, "process with RUN_DIR remains"
                output.seek(0)
                text = output.read()
                if case in ("success", "debug", "real", "stubborn"):
                    assert "[pass] bun MCP daemon boot" in text
                    assert "[pass] swift test" in text and "[pass] bun test" in text
                if case == "suite-failure":
                    assert "[fail] swift test" in text and "[fail] bun test" in text
                print(f"PASS {case}: exit={status}, daemon/descendants gone, RUN_DIR checked", flush=True)
            except Exception as error:
                output.seek(0)
                failures.append(case)
                print(f"FAIL {case}: {error}\n{output.read()}", flush=True)
                for log in run_dir.glob("*.log"):
                    print(f"{log.name}:\n{log.read_text()}", flush=True)
            finally:
                # RED runs must clean up their own intentionally exposed leaks too.
                if runner is not None:
                    if daemon_group is not None:
                        try:
                            os.killpg(daemon_group, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                    suite_pid = Path(str(record) + ".suite")
                    if suite_pid.exists():
                        pids.append(int(suite_pid.read_text()))
                    for pid in [runner.pid, *pids]:
                        try:
                            os.kill(pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                    runner.wait()
finally:
    shutil.rmtree(base)
if failures:
    raise SystemExit("failed cases: " + ", ".join(failures))
PY
