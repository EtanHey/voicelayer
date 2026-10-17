#!/usr/bin/env python3
"""Own the hook smoke's daemon group, including when bash cannot run its trap."""
import os
import json
import fcntl
import ctypes
from pathlib import Path
import re
import shutil
import signal
import stat
import subprocess
import sys
import time


def audit(event, reason, pgid=None, members=(), **fields):
    """Opt-in test evidence lives outside RUN_DIR, which the hook removes."""
    path = os.environ.get("VOICELAYER_HOOK_AUDIT_LOG")
    if not path:
        return
    row = dict(time_ns=time.time_ns(), actor_pid=os.getpid(), event=event,
               reason=reason, pgid=pgid, targets=[p[0] for p in members],
               run_nonce=os.environ.get("VOICELAYER_HOOK_TEST_NONCE"), **fields)
    if event in ("signal-attempt", "signal-sent", "signal-gone"):
        row["sender_pid"] = os.getpid()
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    try:
        os.write(fd, (json.dumps(row) + "\n").encode())
    finally:
        os.close(fd)


def process_identity(pid):
    """Read argv and envp separately; argv text is NEVER ownership evidence."""
    try:
        if sys.platform == "darwin":
            # CTL_KERN / KERN_PROCARGS2: argc, executable path, NUL padding,
            # exactly argc argv strings, then the NUL-terminated envp strings.
            libc = ctypes.CDLL(None, use_errno=True)
            mib = (ctypes.c_int * 3)(1, 49, pid)
            size = ctypes.c_size_t(os.sysconf("SC_ARG_MAX"))
            buffer = ctypes.create_string_buffer(size.value)
            if libc.sysctl(mib, 3, buffer, ctypes.byref(size), None, 0) != 0:
                return None
            raw = buffer.raw[:size.value]
            argc = int.from_bytes(raw[:4], sys.byteorder, signed=True)
            if not 0 < argc < len(raw):
                return None
            offset = raw.index(b"\0", 4) + 1
            while offset < len(raw) and raw[offset] == 0:
                offset += 1
            argv = []
            for _ in range(argc):
                end = raw.index(b"\0", offset)
                argv.append(raw[offset:end])
                offset = end + 1
            entries = raw[offset:].split(b"\0")
        elif sys.platform.startswith("linux"):
            argv = (Path("/proc") / str(pid) / "cmdline").read_bytes().rstrip(b"\0").split(b"\0")
            entries = (Path("/proc") / str(pid) / "environ").read_bytes().split(b"\0")
        else:
            return None
        env = {}
        for entry in entries:
            if not entry:
                break
            key, value = entry.split(b"=", 1)
            key = os.fsdecode(key)
            if key in env:
                return None
            env[key] = os.fsdecode(value)
        return [os.fsdecode(arg) for arg in argv], env
    except (OSError, ValueError, IndexError):
        return None


def processes():
    # ps supplies only process metadata. Native argv/envp reads are separate.
    rows = subprocess.check_output(
        ["ps", "-ax", "-o", "pid=,ppid=,pgid=,uid=,stat="], text=True)
    result = []
    for row in rows.splitlines():
        fields = row.split()
        if len(fields) == 5 and fields[3] == str(os.getuid()) and "Z" not in fields[4]:
            pid = int(fields[0])
            identity = process_identity(pid)
            argv, env = identity if identity is not None else ([], None)
            result.append((pid, int(fields[1]), int(fields[2]), argv, env))
    return result


def carries_run(env, run_dir):
    return env is not None and all(env.get(key) and os.path.isabs(env[key]) and
                                   Path(env[key]) == value
               for key, value in (("VOICELAYER_TMP_ROOT", run_dir),
                                  ("VOICELAYER_MCP_SOCKET_PATH", run_dir / "voicelayer-mcp.sock"),
                                  ("VOICELAYER_SOCKET_PATH", run_dir / "voicelayer.sock")))


def matches_test_scope(env, run_dir):
    """A test sweeper needs native, per-process proof of its private root.

    Scope is independent of the legacy fixture tag/lease: tests intentionally
    remove those to exercise production orphan recovery. An unscoped production
    hook must also leave scoped fixtures alone, even if their lease is unreadable.
    """
    scope = os.environ.get("VOICELAYER_HOOK_TEST_SCOPE")
    target_scope = (env or {}).get("VOICELAYER_HOOK_TEST_SCOPE")
    if scope is None and target_scope is None:
        return True  # Ordinary production hook orphan recovery.
    if not scope or scope != target_scope or not os.path.isabs(scope):
        return False
    try:
        root = Path(scope)
        if root.is_symlink() or not root.is_dir():
            return False
        # Resolve symlinks before checking containment; argv/path prefixes alone
        # cannot prove ownership. Each harness exclusively creates this root.
        return run_dir.resolve().is_relative_to(root.resolve(strict=True))
    except (OSError, ValueError, RuntimeError):
        return False


def live_peer_fixture(env):
    """Only a matching, held lease plus a live owner can exempt a tagged fixture."""
    nonce = (env or {}).get("VOICELAYER_HOOK_TEST_NONCE")
    owner = (env or {}).get("VOICELAYER_HOOK_TEST_OWNER", "")
    if not nonce or not os.path.isabs(owner):
        return False
    # A run's own sweep intentionally exercises its fixtures. Inheriting these
    # values never changes eligibility of UNTAGGED or dead-owner real orphans.
    if (nonce == os.environ.get("VOICELAYER_HOOK_TEST_NONCE") and
            owner == os.environ.get("VOICELAYER_HOOK_TEST_OWNER")):
        return False
    try:
        fd = os.open(owner, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
        with os.fdopen(fd) as lock:
            if not stat.S_ISREG(os.fstat(lock.fileno()).st_mode):
                return False
            lease = json.loads(lock.read(4096))
            pid = lease["pid"]
            if (lease["nonce"] != nonce or type(pid) is not int or pid <= 1 or
                    not isinstance(lease["started"], str) or not lease["started"]):
                return False
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                # A stale PID/metadata file without this held lock is never proof.
                state = subprocess.check_output(
                    ["ps", "-p", str(pid), "-o", "stat=,lstart="], text=True, timeout=1,
                    env=dict(os.environ, LC_ALL="C", TZ="UTC")).split(None, 1)
                return len(state) == 2 and "Z" not in state[0] and state[1].strip() == lease["started"]
            else:
                fcntl.flock(lock, fcntl.LOCK_UN)
                return False
    except (OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError):
        return False


def daemon_argv(argv):
    return any(arg == "src/mcp-server-daemon.ts" or arg.endswith("/src/mcp-server-daemon.ts") for arg in argv)


def reap_group(pgid, run_dir, orphan_only=False):
    def owned_members():
        members = [p for p in processes() if p[2] == pgid]
        if any(p[4] is not None and not matches_test_scope(p[4], run_dir) for p in members):
            audit("skip", "outside test sweep scope", pgid, members)
            return []
        unverified = [p for p in members if not carries_run(p[4], run_dir)]
        if unverified:
            # A different real environment is never ours. An unavailable native
            # identity can be transient during exec/exit; never signal it.
            if any(p[4] is not None for p in unverified):
                audit("skip", "environment ownership mismatch", pgid, members)
                return []
            return None
        if not members:
            return []
        if orphan_only and any(live_peer_fixture(p[4]) for p in members):
            audit("skip", "fixture owner alive", pgid, members)
            return []
        if orphan_only and run_dir.exists():
            audit("skip", "run directory still exists", pgid, members)
            return []
        return members

    def verified_members():
        deadline = time.monotonic() + 2
        while True:
            members = owned_members()
            if members is not None:
                return members
            if time.monotonic() >= deadline:
                if orphan_only:
                    audit("skip", "environment unreadable after retry", pgid)
                    return []  # Unknown environment: skip the entire group.
                raise RuntimeError(f"cannot verify test daemon group {pgid}")
            time.sleep(0.05)

    # Establish the orphan candidate once. TERM can remove its leader/entrypoint;
    # subsequent snapshots still verify EVERY survivor's env and directory.
    if orphan_only and not any(p[1] == 1 and daemon_argv(p[3]) for p in verified_members()):
        return

    # Revalidate before EACH signal. A stale PID/PGID file is never authority
    # to kill a reused group, a resident daemon, or another test run.
    for signum in (signal.SIGTERM, signal.SIGKILL):
        members = verified_members()
        if not members:
            return
        reason = "absent-dir PPID-1 daemon" if orphan_only else "owned daemon cleanup"
        audit("signal-attempt", reason, pgid, members, signal=int(signum), run_dir=str(run_dir))
        try:
            os.killpg(pgid, signum)
            audit("signal-sent", reason, pgid, members, signal=int(signum), run_dir=str(run_dir))
        except ProcessLookupError:
            audit("signal-gone", reason, pgid, members, signal=int(signum))
            return
        deadline = time.monotonic() + 1
        while time.monotonic() < deadline:
            if owned_members() == []:
                return
            time.sleep(0.05)
    if verified_members():
        raise RuntimeError(f"test daemon group {pgid} survived SIGKILL")


def cleanup_group(run_dir):
    try:
        # The spawning supervisor AND its child hold this lock until identity
        # publication. Even SIGKILL between fork and exec cannot hide the child
        # from cleanup by racing an absent state file.
        with (run_dir / "daemon-spawn.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            state = json.loads((run_dir / "daemon-group.json").read_text())
            pid, pgid = state["pid"], state["pgid"]
    except (OSError, ValueError, KeyError, TypeError):
        return
    if type(pid) is int and type(pgid) is int and pid == pgid and pgid > 1:
        reap_group(pgid, run_dir)


def sweep_orphans():
    seen = set()
    for pid, ppid, pgid, argv, env in processes():
        if ppid != 1 or pgid <= 1 or pgid in seen:
            continue
        mcp_socket = (env or {}).get("VOICELAYER_MCP_SOCKET_PATH", "")
        run_dir = Path(mcp_socket).parent
        if (os.path.isabs(mcp_socket) and Path(mcp_socket).name == "voicelayer-mcp.sock" and
                re.fullmatch(r"voicelayer-run-tests\.[0-9]+", run_dir.name) and daemon_argv(argv) and
                carries_run(env, run_dir)):
            seen.add(pgid)
            reap_group(pgid, run_dir, orphan_only=True)


def main():
    if sys.argv[1] == "--cleanup":
        cleanup_group(Path(sys.argv[2]))
        return
    if sys.argv[1] == "--sweep":
        sweep_orphans()
        return
    if sys.argv[1] == "--daemon":
        # Publish from INSIDE the new session, before any daemon/wrapper can
        # exec. Supervisor SIGKILL cannot interrupt a parent-side state write.
        run_dir = Path(sys.argv[2])
        state = run_dir / "daemon-group.json"
        temporary = state.with_suffix(".tmp")
        temporary.write_text(json.dumps({"pid": os.getpid(), "pgid": os.getpgrp()}))
        temporary.replace(state)
        os.close(int(sys.argv[3]))
        os.execvp(sys.argv[4], sys.argv[4:])
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
        audit("signal-received", "supervisor start request", signal=int(_signum))
        start_requested = True

    def request_stop(signum, _frame):
        nonlocal stopping, exiting
        audit("signal-received", "supervisor stop request", signal=int(signum))
        stopping = True
        if signum != signal.SIGUSR1:
            exiting = True

    for signum in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM, signal.SIGUSR1):
        signal.signal(signum, request_stop)
    signal.signal(signal.SIGUSR2, request_start)

    def stop_group(child):
        reap_group(child.pid, run_dir)
        child.wait(timeout=1)

    try:
        # The parent may already have died before Python installed handlers.
        if os.getppid() != parent_pid or exiting:
            return
        # Swift must not begin until detached cleanup ownership is established.
        (run_dir / "supervisor-ready").write_text(str(os.getpid()))
        while not exiting and os.getppid() == parent_pid:
            if start_requested and not started and not stopping:
                started = True
                with (run_dir / "daemon-spawn.lock").open("a") as lock:
                    fcntl.flock(lock, fcntl.LOCK_SH)
                    daemon = subprocess.Popen([sys.executable, __file__, "--daemon", str(run_dir),
                                               str(lock.fileno()), *sys.argv[3:]],
                                              pass_fds=(lock.fileno(),), start_new_session=True)
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
