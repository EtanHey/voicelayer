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
    # Keep the real child's PID lock inside the Bun preload's per-run boundary.
    # Its socket/supervisor fixtures still use this script's short private root.
    test_root = os.environ.get("VOICELAYER_TEST_RUN_ROOT")
    if test_root:
        os.environ["QA_VOICE_MCP_PID_PATH"] = str(pathlib.Path(test_root) / f"hook-{os.getpid()}.pid")
    os.execv(os.environ["HOOK_REAL_BUN"], [os.environ["HOOK_REAL_BUN"], *sys.argv[1:]])
if case in ("stubborn", "KILL-supervisor"):
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    child = subprocess.Popen([sys.executable, "-c",
        "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)", run_dir])
    record.write_text(f"{os.getpid()} {child.pid}")
else:
    record.write_text(str(os.getpid()))
if case == "failure":
    raise SystemExit(7)
if case in ("success", "debug", "stubborn", "suite-failure", "KILL-late", "KILL-supervisor"):
    sock = socket.socket(socket.AF_UNIX)
    sock.bind(os.environ["VOICELAYER_MCP_SOCKET_PATH"])
if case == "KILL-supervisor":
    os.kill(os.getppid(), signal.SIGKILL)
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
protected = []
orphan_pids = []
orphan_groups = []
owned_pid_file = base / "owned-pids"

# All sweep candidates in this test are explicitly owned fixture PIDs. The
# production reaper and native signals are real; resident processes cannot be
# selected even by the intentionally unsafe RED implementation.
executable("python3", "#!" + sys.executable + "\n" + '''
import importlib.util, os, pathlib, sys
if len(sys.argv) > 2 and sys.argv[1].endswith("/scripts/supervise-test-daemon.py") and sys.argv[2] == "--sweep":
    spec = importlib.util.spec_from_file_location("reaper", sys.argv[1])
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    identity = getattr(module, "process_identity", None)
    if identity is not None:
        unreadable = int(os.environ["HOOK_UNREADABLE_PID"])
        module.process_identity = lambda pid: None if pid == unreadable else identity(pid)
    owned = {int(p) for p in pathlib.Path(os.environ["HOOK_OWNED_PIDS"]).read_text().split()}
    snapshot = module.processes
    module.processes = lambda: [p for p in snapshot() if p[0] in owned]
    module.sweep_orphans()
else:
    os.execv(sys.executable, [sys.executable, *sys.argv[1:]])
''')
try:
    def interrupted(signum, _frame):
        raise SystemExit(128 + signum)
    for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(signum, interrupted)
    # Real PPID-1 fixtures, all owned by this test. Never signal resident processes.
    def fixture(name, run_dir, orphan=True, impersonate=False, stubborn_child=False):
        env = dict(os.environ, VOICELAYER_TMP_ROOT=str(run_dir),
                   VOICELAYER_MCP_SOCKET_PATH=str(run_dir / "voicelayer-mcp.sock"),
                   VOICELAYER_SOCKET_PATH=str(run_dir / "voicelayer.sock"))
        if impersonate:
            for key in list(env):
                if key.startswith(("VOICELAYER_", "QA_VOICE_")):
                    del env[key]
        record = base / (name + ".pid")
        code = '''
import os, pathlib, signal, sys, time
if sys.argv[2] == "orphan" and os.fork():
    raise SystemExit(0)
os.setsid()
if sys.argv[3] == "child":
    child = os.fork()
    if child == 0:
        os.execv(sys.executable, [sys.executable, "-c",
            "import os,pathlib,signal,sys,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); "
            "pathlib.Path(sys.argv[1]).write_text(str(os.getpid())); time.sleep(60)", sys.argv[1] + ".child"])
else:
    def record_term(_signum, _frame):
        pathlib.Path(sys.argv[1] + ".term").touch()
    signal.signal(signal.SIGTERM, record_term)
pathlib.Path(sys.argv[1]).write_text(str(os.getpid()))
while True: time.sleep(.05)
'''
        proc = subprocess.Popen([sys.executable, "-c", code, str(record),
                                 "orphan" if orphan else "parented", "child" if stubborn_child else "single",
                                 "src/mcp-server-daemon.ts", "VOICELAYER_TMP_ROOT=" + str(run_dir),
                                 "VOICELAYER_MCP_SOCKET_PATH=" + str(run_dir / "voicelayer-mcp.sock"),
                                 "VOICELAYER_SOCKET_PATH=" + str(run_dir / "voicelayer.sock")], env=env)
        if orphan:
            proc.wait(timeout=5)
        else:
            protected.append(proc)
        assert wait_until(lambda: record.exists() and record.stat().st_size > 0)
        pid = int(record.read_text())
        orphan_pids.append(pid)
        orphan_groups.append(pid)
        if stubborn_child:
            child_record = Path(str(record) + ".child")
            assert wait_until(lambda: child_record.exists() and child_record.stat().st_size > 0)
            orphan_pids.append(int(child_record.read_text()))
        if orphan:
            assert wait_until(lambda: subprocess.check_output(["ps", "-p", str(pid), "-o", "ppid="], text=True).strip() == "1")
        return pid

    stale_dir = base / "voicelayer-run-tests.900001"
    stale_dir.mkdir()
    stale = fixture("stale", stale_dir)
    stale_dir.rmdir()
    concurrent_dir = base / "voicelayer-run-tests.900002"
    concurrent_dir.mkdir()
    concurrent = fixture("concurrent", concurrent_dir)
    parented = fixture("parented", base / "voicelayer-run-tests.900003", orphan=False)
    live = fixture("live", Path("/tmp"))
    unrelated = fixture("unrelated", base / "unrelated-run.900004")
    impersonator = fixture("argv-only", base / "voicelayer-run-tests.900008", impersonate=True)
    terminating_leader = fixture("terminating-leader", base / "voicelayer-run-tests.900009", stubborn_child=True)
    stubborn = orphan_pids[-1]
    unreadable = fixture("unreadable", base / "voicelayer-run-tests.900010")
    owned_pid_file.write_text(" ".join(str(p) for p in orphan_pids))

    # Both review regressions run before the lifecycle matrix. Aggregate their
    # failures so RED must observe the safety defect AND the leaked descendant.
    env = dict(os.environ, PATH=str(bin_dir) + ":" + os.environ["PATH"], HOOK_OWNED_PIDS=str(owned_pid_file),
               HOOK_UNREADABLE_PID=str(unreadable))
    subprocess.run([str(bin_dir / "python3"), str(root / "scripts/supervise-test-daemon.py"), "--sweep"],
                   env=env, check=True, timeout=15)
    for label, predicate in (("argv-only impersonator survives", lambda: alive(impersonator) and not (base / "argv-only.pid.term").exists()),
                             ("unreadable environment is skipped", lambda: alive(unreadable) and not (base / "unreadable.pid.term").exists()),
                             ("TERM leader and stubborn descendant reaped", lambda: not alive(terminating_leader) and not alive(stubborn))):
        if wait_until(predicate):
            print("PASS " + label, flush=True)
        else:
            failures.append(label)
            print("FAIL " + label, flush=True)

    cases = ("KILL-supervisor", "KILL-group", "KILL-swift-build", "KILL-group-swift-build", "KILL-swift-test",
             "success", "failure", "timeout", "INT", "TERM", "HUP", "KILL", "KILL-late", "stubborn", "debug", "suite-failure", "real")
    for case in cases:
        lane = base / case
        lane.mkdir()
        record = lane / "pids"
        env = dict(os.environ, PATH=str(bin_dir) + ":" + os.environ["PATH"], TMPDIR=str(lane) + "/",
                   HOOK_CASE=case, HOOK_RECORD=str(record), HOOK_REAL_BUN=real_bun, HOOK_OWNED_PIDS=str(owned_pid_file))
        env["HOOK_UNREADABLE_PID"] = str(unreadable)
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
                if case in ("KILL-group", "KILL-supervisor"):
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
                if case.startswith("KILL") and case != "KILL-supervisor":
                    expected = -9
                if case == "KILL-supervisor":
                    expected = 1
                daemon_pids = [] if "swift" in case else pids
                assert wait_until(lambda: all(not alive(p) for p in daemon_pids)), f"surviving daemon/descendants: {daemon_pids}"
                assert status == expected, f"exit {status}, expected {expected}"
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
        if case == "success":
            try:
                assert wait_until(lambda: not alive(stale)), "deleted-run orphan was not swept"
                assert all(alive(p) for p in (concurrent, parented, live, unrelated, impersonator, unreadable)), "sweep killed a protected daemon"
                # A stale/forged persisted PID cannot authorize killing a different run.
                import fcntl, json
                state_dir = base / "voicelayer-run-tests.900005"
                state_dir.mkdir()
                with (state_dir / "daemon-spawn.lock").open("a") as lock:
                    fcntl.flock(lock, fcntl.LOCK_SH)
                    cleanup = subprocess.Popen([sys.executable, str(root / "scripts/supervise-test-daemon.py"),
                                                "--cleanup", str(state_dir)])
                    time.sleep(.15)
                    assert cleanup.poll() is None, "cleanup raced unfinished group publication"
                    (state_dir / "daemon-group.json").write_text(json.dumps({"pid": concurrent, "pgid": concurrent}))
                assert cleanup.wait(timeout=5) == 0
                assert alive(concurrent), "stale group identity killed a concurrent run"
                print("PASS sweep: missing-dir orphan reaped; live, concurrent, parented, unrelated and reused-group identities protected", flush=True)
            except Exception as error:
                failures.append("sweep")
                print(f"FAIL sweep: {error}", flush=True)
finally:
    for pid in orphan_groups:
        try:
            os.killpg(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    for proc in protected:
        proc.wait(timeout=5)
    shutil.rmtree(base)
if failures:
    raise SystemExit("failed cases: " + ", ".join(failures))
PY
