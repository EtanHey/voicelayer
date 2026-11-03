"""Isolated macOS quit sampler. Never touches VoiceBar, its gate, or sockets."""
import json
import os
import signal
import subprocess
import time


def identity(pid):
    result = subprocess.run(
        ["/bin/ps", "-p", str(pid), "-o", "lstart=", "-o", "comm="],
        capture_output=True, text=True, timeout=1,
    )
    try:
        os.kill(pid, 0)
        exists = True
    except ProcessLookupError:
        exists = False
    return result.returncode, result.stdout.strip(), exists


pid = os.fork()
if pid == 0:
    os.execl("/bin/sleep", "sleep", "30")
try:
    for _ in range(100):
        _, pinned, _ = identity(pid)
        if pinned.split()[-1].split("/")[-1] == "sleep":
            break
        time.sleep(0.001)
    else:
        raise RuntimeError("scratch child did not exec sleep")
    print(json.dumps(dict(pid=pid, pinned=pinned)), flush=True)
    os.kill(pid, signal.SIGTERM)  # Only the scratch child created above.
    start = time.monotonic()
    seen = set()
    for _ in range(100):
        rc, current, exists = identity(pid)
        # Exact abf040f5 observer branches, with the parent deliberately keeping
        # the child unreaped so the kernel's teardown evidence is observable.
        branch = "alive"
        if rc == 1 and not current and exists:
            branch = "H1 identity throws: empty ps while pid exists"
        elif current != pinned and "<defunct>" not in current:
            branch = "H1 identity mismatch"
        elif "<defunct>" in current:
            branch = "same-birth defunct (old observer already polls)"
        key = (rc, current, exists, branch)
        if key not in seen:
            print(json.dumps(dict(ms=round((time.monotonic()-start)*1000, 3),
                                  rc=rc, identity=current, exists=exists,
                                  old_branch=branch)), flush=True)
            seen.add(key)
        time.sleep(0.001)
    os.waitpid(pid, 0)
    print(json.dumps(dict(after_reap=identity(pid),
                         H2="not injected: no shared gate or lock",
                         H3="not injected: no VoiceBar launched")), flush=True)
finally:
    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    try:
        os.waitpid(pid, 0)
    except ChildProcessError:
        pass
