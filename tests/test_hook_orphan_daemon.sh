#!/usr/bin/env bash
# Exercise the actual hook runner with cheap Swift/Bun-suite shims, no live audio.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 - "$ROOT" "$@" <<'PY'
import fcntl
import importlib.util
import json
import os
import uuid
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time

root = Path(sys.argv[1])
harness_parent = os.getppid()
sys.dont_write_bytecode = True
os.environ["PYTHONDONTWRITEBYTECODE"] = "1"
sys.path.insert(0, str(root / "tests"))
import hook_fixture_registry as registry
if os.environ.get("HOOK_FIXTURE_RUN"):
    registry.register()
registry.sweep(root)
os.environ.setdefault("HOOK_TREE_PID", str(os.getpid()))
os.environ.setdefault("HOOK_TREE_TOKEN", uuid.uuid4().hex)

def publish(path, value):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(value)
    temporary.replace(path)

def build_native(destination):
    compiler = shutil.which("cc")
    if compiler is None:
        print("SKIP HO3 native sender helper: cc toolchain missing", flush=True)
        return False
    result = subprocess.run([compiler, "-shared", "-fPIC", str(root / "tests/hook-term-sender.c"),
                             "-o", str(destination)], capture_output=True, text=True)
    if result.returncode != 0:
        print("FAIL HO3 native sender compilation: " + result.stderr.strip(), flush=True)
        raise SystemExit(1)
    return True

# Scratch, X/Y checkouts and the fixture index live in the isolated run root.
# The evidence base alone stays short in /tmp: run_tests.sh binds
# <base>/<case>/voicelayer-run-tests.<pid>/voicelayer-mcp.sock (sun_path is 104
# bytes). The index under the run root is what makes it recoverable.
run_root = registry.run_root(root)
base = Path(tempfile.mkdtemp(prefix="vlho-", dir="/tmp"))
bin_dir = base / "bin"
bin_dir.mkdir()
real_bun = shutil.which("bun")
term_library = base / "term-sender.so"
nonce = base.name
os.environ["VOICELAYER_HOOK_TEST_NONCE"] = nonce
os.environ["VOICELAYER_HOOK_TEST_SCOPE"] = str(base)
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
os.environ["HOOK_FIXTURE_HELPER"] = str(root / "tests")
guardian, fixture_fd = registry.start(base, root, upstream=harness_parent)
print("HOOK evidence: " + str(base), flush=True)

def finish_wrapper(success):
    registry.finish(guardian, fixture_fd)
    owner_lock.close()
    if success and os.environ.get("HOOK_KEEP_EVIDENCE") != "1":
        shutil.rmtree(base)


if "--native-check" in sys.argv[2:]:
    with tempfile.TemporaryDirectory(prefix="vlho-cc-", dir=run_root) as scratch:
        available = build_native(Path(scratch) / "sender.so")
        finish_wrapper(available)
        raise SystemExit(0 if available else 77)
if "--cross-run" in sys.argv[2:]:
    # Separate Bun processes, preloads and repository roots, as in two worktrees.
    with tempfile.TemporaryDirectory(prefix="vlho-runs-", dir=run_root) as runs:
        children = []
        for run in ("X", "Y"):
            checkout = Path(runs) / run
            (checkout / "tests").mkdir(parents=True)
            (checkout / "scripts").mkdir()
            for name in ("src", "node_modules", "flow-bar", "launchd"):
                (checkout / name).symlink_to(root / name, target_is_directory=True)
            shutil.copy(root / "bunfig.toml", checkout)
            for name in ("hook-orphan-daemon.test.ts", "test_hook_orphan_daemon.sh", "hook-term-sender.c", "hook_fixture_registry.py"):
                shutil.copy(root / "tests" / name, checkout / "tests")
            for name in ("supervise-test-daemon.py", "run_tests.sh", "apply-voicebar-f5-hidutil.sh"):
                shutil.copy(root / "scripts" / name, checkout / "scripts")
            env = dict(os.environ, HOOK_CROSS_RUN_CHILD="1", HOOK_CROSS_RUN_DIR=runs,
                       HOOK_CROSS_RUN_LANE=run)
            output = open(Path(runs) / (run + ".log"), "w+")
            child = registry.spawn([shutil.which("bun"), "test", "tests/hook-orphan-daemon.test.ts"],
                                     cwd=checkout, env=env, stdout=output, stderr=subprocess.STDOUT)
            children.append((child, output))
        failed = False
        for child, output in children:
            try:
                status = child.wait(timeout=290)
            except subprocess.TimeoutExpired:
                child.terminate()
                status = child.wait(timeout=10)
            output.seek(0)
            print(output.read(), end="", flush=True)
            output.close()
            failed |= status != 0
        finish_wrapper(not failed)
        raise SystemExit(int(failed))
if "--concurrent" in sys.argv[2:]:
    with tempfile.TemporaryDirectory(prefix="vlho-pair-", dir=run_root) as pair:
        children = []
        for lane in ("A", "B"):
            env = dict(os.environ, HOOK_PAIR_DIR=pair, HOOK_PAIR_LANE=lane)
            output = open(Path(pair) / (lane + ".log"), "w+")
            child = registry.spawn(["bash", str(root / "tests/test_hook_orphan_daemon.sh")],
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
        finish_wrapper(not failed)
        raise SystemExit(int(failed))
if "--policy-check" not in sys.argv[2:] and not build_native(term_library):
    registry.finish(guardian, fixture_fd)
    owner_lock.close()
    shutil.rmtree(base)
    raise SystemExit(77)
succeeded = False
barriers_done = False
negative_names = ("concurrent", "parented", "live", "unrelated", "argv-only", "unreadable",
                  "outside-root", "symlink-escape", "foreign-cleanup", "unscoped-negative", "dead-owner")
if os.environ.get("HOOK_CROSS_RUN_DIR") or "cross-untagged" in sys.argv[2:]:
    negative_names += ("cross-untagged",)
protected_names = set()
class ProtectedTerm(BaseException):
    pass
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
    for pid in pids:
        record = base / f"fixture-{pid}.json"
        if record.exists():
            saved = json.loads(record.read_text())
            if registry.metadata(pid) != saved["started"]:
                raise RuntimeError(f"refusing signal to reused fixture PID {pid}")
    (os.killpg if group else os.kill)(target, signum)

def term_free(name):
    marker = base / (name + ".pid.term")
    clean = True
    for row in marker.read_text().splitlines() if marker.exists() else ():
        clean = False
        print("FAIL protected TERM: " + row, flush=True)
    return clean

def check_interference():
    if not barriers_done:
        return
    # Abort outside ordinary lifecycle error handlers; teardown still runs.
    if not all(term_free(name) for name in negative_names):
        raise ProtectedTerm("protected fixture received TERM; native sender above")

def final_protected_terms():
    return [name for name in negative_names if not term_free(name)]

if "--policy-check" in sys.argv[2:]:
    assert not issubclass(ProtectedTerm, Exception), "lifecycle error handlers must not swallow protected TERM"
    barriers_done = True
    for membership, script in ((1, "foreign.py"), (-1, "foreign.py"), (0, "foreign.py"), (0, "supervise-test-daemon.py")):
        marker = base / "concurrent.pid.term"
        marker.write_text("sender_pid=42 sender_executable=/python sender_entrypoint=" + script + " sender_in_run=" + str(membership) + "\n")
        assert not term_free("concurrent"), "protected TERM was accepted"
        try:
            check_interference()
        except ProtectedTerm:
            pass
        else:
            raise AssertionError("protected TERM did not abort immediately")
    registry.finish(guardian, fixture_fd)
    owner_lock.close()
    shutil.rmtree(base)
    print("PASS attribution: every protected TERM fails immediately; no retry", flush=True)
    raise SystemExit(0)

def executable(name, body):
    path = bin_dir / name
    payload = bin_dir / (name + "-fixture")
    payload.write_text(body)
    payload.chmod(0o755)
    path.write_text("#!" + sys.executable + "\nimport os, sys\n"
        "sys.dont_write_bytecode = True\n"
        "sys.path.insert(0, os.environ['HOOK_FIXTURE_HELPER'])\n"
        "import hook_fixture_registry as registry\n"
        "registry.exec_registered([" + repr(str(payload)) + ", *sys.argv[1:]])\n")
    path.chmod(0o755)

executable("swift", "#!" + sys.executable + "\n" + '''
import os, pathlib, sys, time
case = os.environ["HOOK_CASE"]
# Regression: cold setup can exceed the old eight seconds from runner launch.
if case == "KILL-supervisor" and sys.argv[1] == "build":
    time.sleep(9)
    print("PASS delayed KILL-supervisor setup: 9 seconds", flush=True)
if case in ("KILL-swift-build", "KILL-group-swift-build", "KILL-swift-test"):
    phase = "test" if case == "KILL-swift-test" else "build"
    if sys.argv[1] == phase:
        pathlib.Path(os.environ["HOOK_RECORD"] + ".swift").write_text(str(os.getpid()))
        time.sleep(60)
''')
executable("plutil", "#!/bin/sh\nexit 0\n")
executable("bun", "#!" + sys.executable + "\n" + '''
import os, pathlib, signal, socket, subprocess, sys, time
sys.path.insert(0, os.environ["HOOK_FIXTURE_HELPER"])
import hook_fixture_registry as registry
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
    child = registry.spawn([sys.executable, "-c",
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
        check_interference()
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
        module.audit("fixture-signal", "guarded native signal", pgid, members,
                     sender_pid=os.getpid(), parent_pid=os.getppid(), signal=int(signum),
                     sender_scope=os.environ.get("VOICELAYER_HOOK_TEST_SCOPE"),
                     target_scopes=[p[4].get("VOICELAYER_HOOK_TEST_SCOPE") for p in members])
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
    zombie = registry.spawn([sys.executable, "-c", "pass"])
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
    def fixture(name, run_dir, orphan=True, impersonate=False, stubborn_child=False, tagged=True, owner=None, scoped=True, protect=True):
        if protect:
            protected_names.add(name)
            assert protected_names <= set(negative_names), "protected fixture missing from monitoring"
        env = dict(os.environ, VOICELAYER_TMP_ROOT=str(run_dir),
                   VOICELAYER_MCP_SOCKET_PATH=str(run_dir / "voicelayer-mcp.sock"),
                   VOICELAYER_SOCKET_PATH=str(run_dir / "voicelayer.sock"))
        if owner is not None:
            env["VOICELAYER_HOOK_TEST_NONCE"] = owner.parent.name
            env["VOICELAYER_HOOK_TEST_OWNER"] = str(owner)
        if not tagged:
            env.pop("VOICELAYER_HOOK_TEST_NONCE")
            env.pop("VOICELAYER_HOOK_TEST_OWNER")
        if not scoped:
            env.pop("VOICELAYER_HOOK_TEST_SCOPE", None)
        if impersonate:
            for key in list(env):
                if key.startswith(("VOICELAYER_", "QA_VOICE_")) and key != "VOICELAYER_HOOK_TEST_NONCE":
                    del env[key]
        record = base / (name + ".pid")
        code = '''
import ctypes, os, pathlib, signal, sys, time
sys.path.insert(0, os.environ["HOOK_FIXTURE_HELPER"])
import hook_fixture_registry as registry
if sys.argv[3] == "child":
    registry.spawn([sys.executable, "-c",
        "import os,pathlib,signal,sys,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); "
        "pathlib.Path(sys.argv[1]).write_text(str(os.getpid())); time.sleep(60)", sys.argv[1] + ".child"])
library = ctypes.CDLL(sys.argv[4])
library.hook_term_sender.argtypes = [ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_int]
assert library.hook_term_sender(os.fsencode(sys.argv[1] + ".term"),
    int(os.environ["HOOK_TREE_PID"]), os.fsencode(os.environ["HOOK_TREE_TOKEN"]), sys.argv[3] == "child") == 0
pathlib.Path(sys.argv[1]).write_text(str(os.getpid()))
while True: time.sleep(.05)
'''
        env["HOOK_FIXTURE_HELPER"] = str(root / "tests")
        proc = registry.spawn([sys.executable, "-c", code, str(record),
                                 "orphan" if orphan else "parented", "child" if stubborn_child else "single",
                                 str(term_library), "src/mcp-server-daemon.ts", "VOICELAYER_TMP_ROOT=" + str(run_dir),
                                 "VOICELAYER_MCP_SOCKET_PATH=" + str(run_dir / "voicelayer-mcp.sock"),
                                 "VOICELAYER_SOCKET_PATH=" + str(run_dir / "voicelayer.sock")], env=env, orphan=orphan)
        if orphan:
            proc.wait(timeout=5)
        else:
            protected.append(proc)
        assert wait_until(lambda: record.exists() and record.stat().st_size > 0)
        pid = int(record.read_text())
        orphan_pids.append(pid)
        if stubborn_child:
            child_record = Path(str(record) + ".child")
            assert wait_until(lambda: child_record.exists() and child_record.stat().st_size > 0)
            orphan_pids.append(int(child_record.read_text()))
        if orphan:
            assert wait_until(lambda: subprocess.check_output(["ps", "-p", str(pid), "-o", "ppid="], text=True).strip() == "1")
        snapshot("created " + name, orphan_pids)
        return pid

    if "--protected-term-check" in sys.argv[2:]:
        name, phase = sys.argv[-2:]
        assert name in ("cross-untagged", "unscoped-negative")
        assert phase in ("ongoing", "final")
        pid = fixture(name, base / "voicelayer-run-tests.900022", tagged=False)
        assert alive(pid) and term_free(name), "one-off protection check failed"
        print("PASS one-off protection check: " + name, flush=True)
        signal_reason = "regression: TERM after one-off check"
        owned_signal(pid, signal.SIGTERM)
        # Wait directly: the ongoing checker is the subject of this regression.
        marker = base / (name + ".pid.term")
        deadline = time.monotonic() + 5
        while not marker.exists() and time.monotonic() < deadline:
            time.sleep(.01)
        assert marker.exists(), "native TERM receipt missing"
        barriers_done = True
        if phase == "ongoing":
            check_interference()
        elif final_protected_terms():
            raise ProtectedTerm("protected fixture TERM after lifecycle")
        succeeded = True
        raise SystemExit(0)

    if "--abort-fixture-check" in sys.argv[2:]:
        (base / "escape").symlink_to(base.parent / (nonce + "-outside"))
        fixture("symlink-escape", base / "escape" / "voicelayer-run-tests.900024")
        print("ABORT READY", flush=True)
        while True:
            assert os.getppid() == harness_parent, "abort driver disappeared"
            assert not (base / "fail-assertion").exists(), "injected assertion failure"
            time.sleep(.05)

    stale_dir = base / "voicelayer-run-tests.900001"
    stale_dir.mkdir()
    stale = fixture("stale", stale_dir, protect=False)
    stale_dir.rmdir()
    concurrent_dir = base / "voicelayer-run-tests.900002"
    concurrent_dir.mkdir()
    concurrent = fixture("concurrent", concurrent_dir)
    parented = fixture("parented", base / "voicelayer-run-tests.900003", orphan=False)
    live = fixture("live", Path("/tmp"))
    unrelated = fixture("unrelated", base / "unrelated-run.900004")
    impersonator = fixture("argv-only", base / "voicelayer-run-tests.900008", impersonate=True)
    terminating_leader = fixture("terminating-leader", base / "voicelayer-run-tests.900009", stubborn_child=True, protect=False)
    stubborn = orphan_pids[-1]
    unreadable = fixture("unreadable", base / "voicelayer-run-tests.900010")
    owned_pid_file.write_text(" ".join(str(p) for p in orphan_pids))

    # Both review regressions run before the lifecycle matrix. Aggregate their
    # failures so RED must observe the safety defect AND the leaked descendant.
    env = dict(os.environ, PATH=str(bin_dir) + ":" + os.environ["PATH"], HOOK_OWNED_PIDS=str(owned_pid_file),
               HOOK_UNREADABLE_PID=str(unreadable))
    cross = os.environ.get("HOOK_CROSS_RUN_DIR")
    if cross:
        # Exercise a peer's untagged orphan without HO2 lease exemptions.
        sentinel = fixture("cross-untagged", base / "voicelayer-run-tests.900020", tagged=False)
        lane = os.environ["HOOK_CROSS_RUN_LANE"] + os.environ["HOOK_PAIR_LANE"]
        peer = ("Y" if lane[0] == "X" else "X") + lane[1]
        manifest = Path(cross) / (lane + ".json")
        publish(manifest, json.dumps(dict(pid=sentinel, base=str(base))))
        peer_manifest = Path(cross) / (peer + ".json")
        assert wait_until(peer_manifest.exists, 30), "other Bun process never published"
        target = json.loads(peer_manifest.read_text())
        selected = base / "cross-target"
        selected.write_text(str(target["pid"]))
        subprocess.run([str(bin_dir / "python3"), str(root / "scripts/supervise-test-daemon.py"), "--sweep"],
                       env=dict(env, HOOK_OWNED_PIDS=str(selected), HOOK_FOREIGN_ROOT=target["base"]), check=True, timeout=15)
        (Path(cross) / (lane + ".swept")).touch()
        assert wait_until(lambda: (Path(cross) / (peer + ".swept")).exists(), 30)
        if not term_free("cross-untagged") or not alive(sentinel):
            failures.append("cross-run TERM")
            print("FAIL cross-run TERM: " + str(base / "cross-untagged.pid.term"), flush=True)
        else:
            print("PASS independent Bun roots: no sweep cross-TERM", flush=True)
        (Path(cross) / (lane + ".checked")).touch()
        assert wait_until(lambda: (Path(cross) / (peer + ".checked")).exists(), 30)
    pair = os.environ.get("HOOK_PAIR_DIR")
    if pair:
        lane = os.environ["HOOK_PAIR_LANE"]
        peer = Path(pair) / ("B" if lane == "A" else "A")
        publish(Path(pair) / lane, str(base))
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
    barriers_done = True
    check_interference()
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

    # Actual native fixtures: neither a live-shaped path nor a test-looking
    # directory outside this run may authorize a signal. Also cover --cleanup.
    outside_dir = base.parent / (nonce + "-outside") / "voicelayer-run-tests.900021"
    outside = fixture("outside-root", outside_dir)
    sweep_selected([outside], env)
    check_case("outside-root fixture receives no owned TERM", lambda: alive(outside) and term_free("outside-root"))
    (base / "escape").symlink_to(outside_dir.parent, target_is_directory=True)
    escaped = fixture("symlink-escape", base / "escape" / "voicelayer-run-tests.900024")
    sweep_selected([escaped], env)
    check_case("symlink escape receives no owned TERM", lambda: alive(escaped) and term_free("symlink-escape"))
    scoped = fixture("unscoped-negative", base / "voicelayer-run-tests.900022", tagged=False)
    production_env = {k: v for k, v in env.items() if k not in (
        "VOICELAYER_HOOK_TEST_SCOPE", "VOICELAYER_HOOK_TEST_NONCE", "VOICELAYER_HOOK_TEST_OWNER")}
    sweep_selected([scoped], production_env)
    check_case("unscoped sweep cannot signal scoped fixture", lambda: alive(scoped) and term_free("unscoped-negative"))
    production = fixture("production-untagged", base / "voicelayer-run-tests.900025", tagged=False, scoped=False, protect=False)
    sweep_selected([production], production_env)
    check_case("production sweep still reaps unscoped orphan", lambda: not alive(production))
    cleanup_dir = base / "voicelayer-run-tests.900023"
    cleanup_dir.mkdir()
    saved_scope = os.environ["VOICELAYER_HOOK_TEST_SCOPE"]
    try:
        os.environ["VOICELAYER_HOOK_TEST_SCOPE"] = str(base.parent / (nonce + "-foreign"))
        foreign = fixture("foreign-cleanup", cleanup_dir)
    finally:
        os.environ["VOICELAYER_HOOK_TEST_SCOPE"] = saved_scope
    (cleanup_dir / "daemon-group.json").write_text(json.dumps(dict(pid=foreign, pgid=foreign)))
    subprocess.run([sys.executable, str(root / "scripts/supervise-test-daemon.py"), "--cleanup", str(cleanup_dir)],
                   env=env, check=True, timeout=15)
    check_case("cleanup cannot signal foreign scope", lambda: alive(foreign) and term_free("foreign-cleanup"))

    # Inherited test state must never exempt an ordinary production orphan.
    inherited = fixture("inherited-untagged", base / "voicelayer-run-tests.900012", tagged=False, protect=False)
    sweep_selected([inherited], env)
    check_case("inherited-nonce sweeper reaps untagged orphan", lambda: not alive(inherited))

    # A separate owner holds a real lease, then is SIGKILLed like a killed harness.
    dead_owner_path = base / "dead-owner" / "fixture-owner.lock"
    dead_owner_path.parent.mkdir()
    owner_code = """
import fcntl, json, os, pathlib, subprocess, sys, time
sys.path.insert(0, os.environ["HOOK_FIXTURE_HELPER"])
import hook_fixture_registry as registry
path = pathlib.Path(sys.argv[1])
with path.open("w+") as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    started = subprocess.check_output(["ps", "-p", str(os.getpid()), "-o", "lstart="], text=True,
    env=dict(os.environ, LC_ALL="C", TZ="UTC")).strip()
    lock.write(json.dumps(dict(pid=os.getpid(), nonce=path.parent.name, started=started)))
    lock.flush()
    while True: time.sleep(.05)
"""
    owner_process = registry.spawn([sys.executable, "-c", owner_code, str(dead_owner_path)])
    try:
        assert wait_until(lambda: dead_owner_path.exists() and dead_owner_path.stat().st_size > 0)
        leaked = fixture("dead-owner", base / "voicelayer-run-tests.900013", owner=dead_owner_path)
        sweep_selected([leaked], env)
        check_case("tagged orphan protected while owner alive", lambda: alive(leaked) and term_free("dead-owner"))
    finally:
        # Protection ends deliberately when its owner dies; the next sweep must reap it.
        negative_names = tuple(name for name in negative_names if name != "dead-owner")
        protected_names.discard("dead-owner")
        signal_reason = "SIGKILL fixture owner to release lease"
        owner_process.kill()
        owner_process.wait(timeout=5)
    sweep_selected([leaked], env)
    check_case("tagged orphan reaped after owner SIGKILL", lambda: not alive(leaked))
    # A stray tag with no verifiable owner must not be a permanent exemption.
    stray = fixture("stray", base / "voicelayer-run-tests.900014", owner=base / "missing-owner" / "fixture-owner.lock", protect=False)
    sweep_selected([stray], env)
    check_case("stray nonce without live owner is reaped", lambda: not alive(stray))

    unheld_owner = base / "unheld-owner" / "fixture-owner.lock"
    unheld_owner.parent.mkdir()
    unheld_owner.write_text(json.dumps(dict(pid=os.getpid(), nonce=unheld_owner.parent.name, started=owner_started)))
    unheld = fixture("unheld-owner", base / "voicelayer-run-tests.900015", owner=unheld_owner, protect=False)
    sweep_selected([unheld], env)
    check_case("live PID without held owner lock is not exempt", lambda: not alive(unheld))

    # An ordinary hook has no test nonce and must also leave ALL fixtures alone.
    tagged_pids = [stale, concurrent, parented, live, unrelated, impersonator,
                   terminating_leader, stubborn, unreadable]
    untagged = fixture("untagged", base / "voicelayer-run-tests.900011", tagged=False, protect=False)
    # These scoped, untagged sentinels are protected against OTHER scopes above.
    # Our own scoped sweep may legitimately reap them, so never select them in
    # the broad lifecycle sweeps. Keep monitoring their native TERM receipts.
    protected_untagged = {scoped}
    if cross:
        protected_untagged.add(sentinel)
    owned_pid_file.write_text(" ".join(str(p) for p in orphan_pids if p not in protected_untagged))
    unscoped_env = dict(env)
    unscoped_env.pop("VOICELAYER_HOOK_TEST_NONCE")
    subprocess.run([str(bin_dir / "python3"), str(root / "scripts/supervise-test-daemon.py"), "--sweep"],
                   env=unscoped_env, check=True, timeout=15)
    assert all(alive(p) for p in tagged_pids), "unscoped sweep touched fixtures"
    assert wait_until(lambda: not alive(untagged)), "production orphan was not swept"
    print("PASS unscoped sweep protects tagged fixtures and reaps untagged orphan", flush=True)
    subprocess.run([str(bin_dir / "python3"), str(root / "scripts/supervise-test-daemon.py"), "--sweep"],
                   env=env, check=True, timeout=15)
    for label, predicate in (("argv-only impersonator survives", lambda: alive(impersonator) and term_free("argv-only")),
                             ("unreadable environment is skipped", lambda: alive(unreadable) and term_free("unreadable")),
                             ("TERM leader and stubborn descendant reaped", lambda: not alive(terminating_leader) and not alive(stubborn))):
        if wait_until(predicate):
            print("PASS " + label, flush=True)
        else:
            failures.append(label)
            print("FAIL " + label, flush=True)
        snapshot(label, orphan_pids)

    cases = ("KILL-supervisor", "KILL-group", "KILL-swift-build", "KILL-group-swift-build", "KILL-swift-test",
             "success", "failure", "timeout", "INT", "TERM", "HUP", "KILL", "KILL-late", "stubborn", "debug", "suite-failure", "real")
    if "--abort-lifecycle-check" in sys.argv[2:]:
        cases = (sys.argv[-1],)
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
                runner = registry.spawn(["bash", "-c",
                    "PS4='+ elapsed=${SECONDS}s sender=$$ '; set -x; source \"$1\"",
                    "hook-runner", str(root / "scripts/run_tests.sh")], env=env,
                                          stdout=output, stderr=output, start_new_session=True)
                audit("runner-start", case=case, runner_pid=runner.pid)
                run_dir = lane / f"voicelayer-run-tests.{runner.pid}"
                # Sweep/interpreter/Swift setup is not daemon startup. First observe
                # the detached owner's readiness, then give PID publication its own
                # bounded budget. A fast runner may already have published and exited.
                ready = run_dir / "supervisor-ready"
                assert wait_until(lambda: ready.exists() or record.exists() or runner.poll() is not None, 60), "supervisor never became ready"
                def fixture_started(path):
                    return path.exists() and path.stat().st_size > 0
                def await_fixture(path):
                    assert wait_until(lambda: fixture_started(path) or runner.poll() is not None, 60), "fixture startup deadline expired"
                    assert fixture_started(path), "runner exited before fixture readiness"
                if "swift" in case:
                    swift_record = Path(str(record) + ".swift")
                    await_fixture(swift_record)
                    pids = [int(swift_record.read_text())]
                    assert run_dir.exists() and not record.exists(), "early test must precede daemon start"
                else:
                    await_fixture(record)
                    pids = [int(p) for p in record.read_text().split()]
                if case in ("KILL-group", "KILL-supervisor"):
                    daemon_group = os.getpgid(pids[0])
                    assert daemon_group != runner.pid, "daemon shares caller group"
                if "--abort-lifecycle-check" in sys.argv[2:]:
                    if case == "KILL-late":
                        assert wait_until(lambda: Path(str(record) + ".suite").exists()), "suite never started"
                    print("ABORT READY " + case, flush=True)
                    while True:
                        assert os.getppid() == harness_parent, "abort driver disappeared"
                        time.sleep(.05)
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
                if case == "KILL-supervisor":
                    assert "PASS delayed KILL-supervisor setup: 9 seconds" in text
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
                assert all(term_free(name) for name in
                               ("concurrent", "parented", "live", "unrelated", "argv-only", "unreadable")), "protected fixture received TERM"
                # A stale/forged persisted PID cannot authorize killing a different run.
                import fcntl, json
                state_dir = base / "voicelayer-run-tests.900005"
                state_dir.mkdir()
                with (state_dir / "daemon-spawn.lock").open("a") as lock:
                    fcntl.flock(lock, fcntl.LOCK_SH)
                    cleanup = registry.spawn([sys.executable, str(root / "scripts/supervise-test-daemon.py"),
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
    assert set(negative_names) == protected_names, "monitored set differs from created protected fixtures"
    print("PASS monitored set equals protected fixtures: " + ", ".join(sorted(protected_names)), flush=True)
    unexpected_terms = final_protected_terms()
    if unexpected_terms:
        failures.append("protected fixture TERM after lifecycle")
        print("FAIL protected fixture TERM after lifecycle: " + ", ".join(unexpected_terms), flush=True)
    else:
        print("PASS protected fixtures: no TERM throughout lifecycle", flush=True)
    decisions = [json.loads(line) for line in (base / "decisions.jsonl").read_text().splitlines()]
    sent = [row for row in decisions if row["event"] == "signal-sent" and row.get("pgid")]
    assert sent and all(row["sender_pid"] > 1 and row["time_ns"] > 0 and
                        str(row["run_dir"]).startswith(str(base) + "/") for row in sent)
    assert not any(set(row["targets"]) & {impersonator, unreadable} for row in sent)
    assert any(row["signal"] == 9 and stubborn in row["targets"] for row in sent)
    assert any(row["reason"] == "fixture owner alive" for row in decisions)
    print("PASS audit records scoped senders, targets, signals, times and reasons", flush=True)
    succeeded = not failures
except ProtectedTerm as error:
    failures.append(str(error))
finally:
    # Snapshot before cleanup so a failed predicate is distinguishable from our teardown.
    audit("final-snapshot", failures=failures, processes=subprocess.run(
        ["ps", "-p", ",".join(map(str, orphan_pids)) or str(os.getpid()),
         "-o", "pid=,ppid=,pgid=,stat=,lstart=,command="], text=True, capture_output=True).stdout.splitlines()
        if not succeeded else [], term_markers=[p.name for p in base.glob("*.term")])
    signal_reason = "final fixture teardown"
    registry.finish(guardian, fixture_fd)
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
