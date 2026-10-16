#!/usr/bin/env bash
# Exercise the actual hook runner with cheap Swift/Bun-suite shims, no live audio.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 - "$ROOT" "$@" <<'PY'
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time

root = Path(sys.argv[1])
if "--concurrent" in sys.argv[2:]:
    with tempfile.TemporaryDirectory(prefix="vlho-pair-", dir="/tmp") as pair:
        children = []
        for lane in ("A", "B"):
            env = dict(os.environ, HOOK_PAIR_DIR=pair, HOOK_PAIR_LANE=lane)
            output = open(Path(pair) / (lane + ".log"), "w+")
            child = subprocess.Popen(["bash", str(root / "tests/test_hook_orphan_daemon.sh")],
                                     env=env, stdout=output, stderr=subprocess.STDOUT)
            children.append((child, output))
        failed = False
        for child, output in children:
            try:
                status = child.wait(timeout=240)
            except subprocess.TimeoutExpired:
                child.terminate()
                status = child.wait(timeout=30)
            output.seek(0)
            print(output.read(), end="", flush=True)
            output.close()
            failed |= status != 0
        raise SystemExit(int(failed))
base = Path(tempfile.mkdtemp(prefix="vlho-", dir="/tmp"))
bin_dir = base / "bin"
bin_dir.mkdir()
real_bun = shutil.which("bun")
nonce = base.name
os.environ["VOICELAYER_HOOK_TEST_NONCE"] = nonce
owner_path = base / "fixture-owner.lock"
owner_lock = owner_path.open("w+")
fcntl.flock(owner_lock, fcntl.LOCK_EX)
assert not os.get_inheritable(owner_lock.fileno())
# Popen closes this non-inheritable FD; SIGKILL of the harness releases the lease.
owner_started = subprocess.check_output(["ps", "-p", str(os.getpid()), "-o", "lstart="], text=True,
    env=dict(os.environ, LC_ALL="C", TZ="UTC")).strip()
owner_lock.write(json.dumps(dict(pid=os.getpid(), nonce=nonce, started=owner_started)))
owner_lock.flush()
os.environ["VOICELAYER_HOOK_TEST_OWNER"] = str(owner_path)
os.environ["VOICELAYER_HOOK_AUDIT_LOG"] = str(base / "decisions.jsonl")
print("HOOK evidence: " + str(base), flush=True)
succeeded = False
signal_reason = "fixture cleanup"

def audit(event, **fields):
    row = dict(time_ns=time.time_ns(), sender_pid=os.getpid(), event=event, **fields)
    with (base / "harness.jsonl").open("a") as stream:
        stream.write(json.dumps(row) + "\n")

def signal_audit(event, args):
    if event in ("os.kill", "os.killpg"):
        audit(event, target=args[0], signal=int(args[1]), reason=signal_reason)
sys.addaudithook(signal_audit)
identity_spec = importlib.util.spec_from_file_location("identity", root / "scripts/supervise-test-daemon.py")
identity_module = importlib.util.module_from_spec(identity_spec)
identity_spec.loader.exec_module(identity_module)

def owned_signal(target, signum, group=False):
    if group:
        rows = subprocess.check_output(["ps", "-ax", "-o", "pid=,pgid=,stat="], text=True)
        pids = [int(f[0]) for row in rows.splitlines() if len(f := row.split()) == 3
                and int(f[1]) == target and "Z" not in f[2]]
    else:
        pids = [target] if alive(target) else []
    if not pids:
        return
    identities = [identity_module.process_identity(pid) for pid in pids]
    # A numeric PID file alone is never authority after process exit/PID reuse.
    if not all(identity is not None and (
            identity[1].get("VOICELAYER_HOOK_TEST_NONCE") == nonce or
            identity[1].get("VOICELAYER_HOOK_AUDIT_LOG") == str(base / "decisions.jsonl")) for identity in identities):
        raise RuntimeError(f"refusing signal to unverified fixture {target}")
    (os.killpg if group else os.kill)(target, signum)

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
    import json
    with pathlib.Path(os.environ["VOICELAYER_HOOK_AUDIT_LOG"]).open("a") as log:
        log.write(json.dumps(dict(time_ns=time.time_ns(), sender_pid=os.getpid(),
            event="signal-sent", target_pid=os.getppid(), signal=9,
            reason="fixture kills its own supervisor")) + "\\n")
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

def snapshot(label, pids):
    states = subprocess.run(["ps", "-p", ",".join(map(str, pids)),
                             "-o", "pid=,ppid=,pgid=,stat=,lstart="],
                            text=True, capture_output=True).stdout
    audit("snapshot", label=label, states=states,
          term_markers=[p.name for p in base.glob("*.term")])

def alive(pid):
    try:
        state = subprocess.run(["ps", "-p", str(pid), "-o", "stat="],
                               text=True, capture_output=True, check=False).stdout.strip()
        return bool(state) and "Z" not in state
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
    identity = module.process_identity
    unreadable = int(os.environ["HOOK_UNREADABLE_PID"])
    observed = set()
    def fixture_identity(pid):
        result = None if pid == unreadable else identity(pid)
        if pid in owned and (pid, result is not None) not in observed:
            observed.add((pid, result is not None))
            module.audit("identity", "sweep fixture observation", target_pid=pid,
                         environment_readable=result is not None,
                         injected_unreadable=pid == unreadable)
        return result
    module.process_identity = fixture_identity
    owned = {int(p) for p in pathlib.Path(os.environ["HOOK_OWNED_PIDS"]).read_text().split()}
    snapshot = module.processes
    module.processes = lambda: [p for p in snapshot() if p[0] in owned]
    killpg = os.killpg
    def owned_signal(pgid, signum):
        members = [p for p in snapshot() if p[2] == pgid]
        assert members and all(p[0] in owned for p in members), "non-fixture signal refused"
        killpg(pgid, signum)
    os.killpg = owned_signal
    module.sweep_orphans()
else:
    os.execv(sys.executable, [sys.executable, *sys.argv[1:]])
''')
try:
    def interrupted(signum, _frame):
        raise SystemExit(128 + signum)
    for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(signum, interrupted)
    # A dead child awaiting wait() must never count as a running fixture.
    zombie = subprocess.Popen([sys.executable, "-c", "pass"])
    try:
        assert wait_until(lambda: "Z" in subprocess.run(
            ["ps", "-p", str(zombie.pid), "-o", "stat="],
            capture_output=True, text=True).stdout)
        os.kill(zombie.pid, 0)
        assert not alive(zombie.pid), "zombie counted as alive"
        print("PASS zombie is not alive", flush=True)
    finally:
        zombie.wait()
    # Real PPID-1 fixtures, all owned by this test. Never signal resident processes.
    def fixture(name, run_dir, orphan=True, impersonate=False, stubborn_child=False, tagged=True, owner=None):
        env = dict(os.environ, VOICELAYER_TMP_ROOT=str(run_dir),
                   VOICELAYER_MCP_SOCKET_PATH=str(run_dir / "voicelayer-mcp.sock"),
                   VOICELAYER_SOCKET_PATH=str(run_dir / "voicelayer.sock"))
        if owner is not None:
            env["VOICELAYER_HOOK_TEST_NONCE"] = owner.parent.name
            env["VOICELAYER_HOOK_TEST_OWNER"] = str(owner)
        if not tagged:
            env.pop("VOICELAYER_HOOK_TEST_NONCE")
            env.pop("VOICELAYER_HOOK_TEST_OWNER")
        if impersonate:
            for key in list(env):
                if key.startswith(("VOICELAYER_", "QA_VOICE_")) and key != "VOICELAYER_HOOK_TEST_NONCE":
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
        pathlib.Path(sys.argv[1] + ".term").write_text(
            f"time_ns={time.time_ns()} receiver_pid={os.getpid()} signal={_signum}\\n")
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
        snapshot("created " + name, orphan_pids)
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
    pair = os.environ.get("HOOK_PAIR_DIR")
    if pair:
        lane = os.environ["HOOK_PAIR_LANE"]
        peer = Path(pair) / ("B" if lane == "A" else "A")
        (Path(pair) / lane).write_text(str(base))
        assert wait_until(peer.exists, 30), "peer never published fixtures"
        peer_base = Path(peer.read_text())
        # Restrict the REAL sweep to peer fixtures: no resident is ever eligible.
        # The peer's unreadable fixture is readable here, like a different hook.
        foreign_env = dict(env, HOOK_OWNED_PIDS=str(peer_base / "owned-pids"))
        subprocess.run([str(bin_dir / "python3"), str(root / "scripts/supervise-test-daemon.py"), "--sweep"],
                       env=foreign_env, check=True, timeout=15)
        (Path(pair) / (lane + ".swept")).touch()
        assert wait_until(lambda: Path(str(peer) + ".swept").exists(), 30), "peer sweep not finished"
        if not all(alive(p) for p in orphan_pids):
            failures.append("foreign sweep touched fixtures")
            print("FAIL foreign sweep touched fixtures", flush=True)
        else:
            print("PASS foreign sweep leaves peer fixtures alive", flush=True)
    def sweep_selected(pids, sweep_env):
        selected = base / "selected-pids"
        selected.write_text(" ".join(map(str, pids)))
        subprocess.run([str(bin_dir / "python3"), str(root / "scripts/supervise-test-daemon.py"), "--sweep"],
                       env=dict(sweep_env, HOOK_OWNED_PIDS=str(selected)), check=True, timeout=15)

    def check_case(label, predicate):
        # sweep_selected is synchronous and waits for reap completion.
        if wait_until(predicate, 1):
            print("PASS " + label, flush=True)
        else:
            failures.append(label)
            print("FAIL " + label, flush=True)
        snapshot(label, orphan_pids)

    # Inherited test state must never exempt an ordinary production orphan.
    inherited = fixture("inherited-untagged", base / "voicelayer-run-tests.900012", tagged=False)
    sweep_selected([inherited], env)
    check_case("inherited-nonce sweeper reaps untagged orphan", lambda: not alive(inherited))

    # A separate owner holds a real lease, then is SIGKILLed like a killed harness.
    dead_owner_path = base / "dead-owner" / "fixture-owner.lock"
    dead_owner_path.parent.mkdir()
    owner_code = """
import fcntl, json, os, pathlib, subprocess, sys, time
path = pathlib.Path(sys.argv[1])
with path.open("w+") as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    started = subprocess.check_output(["ps", "-p", str(os.getpid()), "-o", "lstart="], text=True,
    env=dict(os.environ, LC_ALL="C", TZ="UTC")).strip()
    lock.write(json.dumps(dict(pid=os.getpid(), nonce=path.parent.name, started=started)))
    lock.flush()
    while True: time.sleep(.05)
"""
    owner_process = subprocess.Popen([sys.executable, "-c", owner_code, str(dead_owner_path)])
    try:
        assert wait_until(lambda: dead_owner_path.exists() and dead_owner_path.stat().st_size > 0)
        leaked = fixture("dead-owner", base / "voicelayer-run-tests.900013", owner=dead_owner_path)
        sweep_selected([leaked], env)
        check_case("tagged orphan protected while owner alive", lambda: alive(leaked) and not (base / "dead-owner.pid.term").exists())
    finally:
        signal_reason = "SIGKILL fixture owner to release lease"
        owner_process.kill()
        owner_process.wait(timeout=5)
    sweep_selected([leaked], env)
    check_case("tagged orphan reaped after owner SIGKILL", lambda: not alive(leaked))
    # A stray tag with no verifiable owner must not be a permanent exemption.
    stray = fixture("stray", base / "voicelayer-run-tests.900014", owner=base / "missing-owner" / "fixture-owner.lock")
    sweep_selected([stray], env)
    check_case("stray nonce without live owner is reaped", lambda: not alive(stray))

    unheld_owner = base / "unheld-owner" / "fixture-owner.lock"
    unheld_owner.parent.mkdir()
    unheld_owner.write_text(json.dumps(dict(pid=os.getpid(), nonce=unheld_owner.parent.name, started=owner_started)))
    unheld = fixture("unheld-owner", base / "voicelayer-run-tests.900015", owner=unheld_owner)
    sweep_selected([unheld], env)
    check_case("live PID without held owner lock is not exempt", lambda: not alive(unheld))

    # An ordinary hook has no test nonce and must also leave ALL fixtures alone.
    tagged_pids = [stale, concurrent, parented, live, unrelated, impersonator,
                   terminating_leader, stubborn, unreadable]
    untagged = fixture("untagged", base / "voicelayer-run-tests.900011", tagged=False)
    owned_pid_file.write_text(" ".join(str(p) for p in orphan_pids))
    unscoped_env = dict(env)
    unscoped_env.pop("VOICELAYER_HOOK_TEST_NONCE")
    subprocess.run([str(bin_dir / "python3"), str(root / "scripts/supervise-test-daemon.py"), "--sweep"],
                   env=unscoped_env, check=True, timeout=15)
    assert all(alive(p) for p in tagged_pids), "unscoped sweep touched fixtures"
    assert wait_until(lambda: not alive(untagged)), "production orphan was not swept"
    print("PASS unscoped sweep protects tagged fixtures and reaps untagged orphan", flush=True)
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
        snapshot(label, orphan_pids)

    cases = ("KILL-supervisor", "KILL-group", "KILL-swift-build", "KILL-group-swift-build", "KILL-swift-test",
             "success", "failure", "timeout", "INT", "TERM", "HUP", "KILL", "KILL-late", "stubborn", "debug", "suite-failure", "real")
    for case in cases:
        signal_reason = case + " fault injection"
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
                runner = subprocess.Popen(["bash", "-c",
                    "PS4='+ elapsed=${SECONDS}s sender=$$ '; set -x; source \"$1\"",
                    "hook-runner", str(root / "scripts/run_tests.sh")], env=env,
                                          stdout=output, stderr=output, start_new_session=True)
                audit("runner-start", case=case, runner_pid=runner.pid)
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
                            rows = subprocess.check_output(["ps", "-ax", "-o", "pgid=,stat="], text=True)
                            return not any(int(f[0]) == daemon_group and "Z" not in f[1]
                                           for row in rows.splitlines() if len(f := row.split()) == 2)
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
                signal_reason = case + " teardown"
                snapshot(case + " before teardown", pids)
                if runner is not None:
                    if daemon_group is not None:
                        try:
                            owned_signal(daemon_group, signal.SIGKILL, group=True)
                        except ProcessLookupError:
                            pass
                    suite_pid = Path(str(record) + ".suite")
                    if suite_pid.exists():
                        pids.append(int(suite_pid.read_text()))
                    for pid in [runner.pid, *pids]:
                        try:
                            owned_signal(pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                    runner.wait()
        if case == "success":
            try:
                assert wait_until(lambda: not alive(stale)), "deleted-run orphan was not swept"
                assert all(alive(p) for p in (concurrent, parented, live, unrelated, impersonator, unreadable)), "sweep killed a protected daemon"
                assert not any((base / (name + ".pid.term")).exists() for name in
                               ("concurrent", "parented", "live", "unrelated", "argv-only", "unreadable")), "protected fixture received TERM"
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
    decisions = [json.loads(line) for line in (base / "decisions.jsonl").read_text().splitlines()]
    sent = [row for row in decisions if row["event"] == "signal-sent" and row.get("pgid")]
    assert sent and all(row["sender_pid"] > 1 and row["time_ns"] > 0 and
                        str(row["run_dir"]).startswith(str(base) + "/") for row in sent)
    assert not any(set(row["targets"]) & {impersonator, unreadable} for row in sent)
    assert any(row["signal"] == 9 and stubborn in row["targets"] for row in sent)
    assert any(row["reason"] == "fixture owner alive" for row in decisions)
    print("PASS audit records scoped senders, targets, signals, times and reasons", flush=True)
    succeeded = not failures
finally:
    # Snapshot before cleanup so a failed predicate is distinguishable from our teardown.
    audit("final-snapshot", failures=failures, processes=subprocess.run(
        ["ps", "-p", ",".join(map(str, orphan_pids)) or str(os.getpid()),
         "-o", "pid=,ppid=,pgid=,stat=,lstart=,command="], text=True, capture_output=True).stdout.splitlines()
        if not succeeded else [], term_markers=[p.name for p in base.glob("*.term")])
    signal_reason = "final fixture teardown"
    for pid in orphan_groups:
        try:
            owned_signal(pid, signal.SIGKILL, group=True)
        except ProcessLookupError:
            pass
    for proc in protected:
        proc.wait(timeout=5)
    owner_lock.close()
    if succeeded and os.environ.get("HOOK_KEEP_EVIDENCE") != "1":
        shutil.rmtree(base)
    else:
        print("Retained HOOK evidence: " + str(base), flush=True)
if failures:
    raise SystemExit("failed cases: " + ", ".join(failures))
PY
