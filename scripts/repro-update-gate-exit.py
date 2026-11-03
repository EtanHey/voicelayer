"""M1-only isolated AppKit quit sampler; run through the captain heavy lock.

Never launches the installed VoiceBar or reads/writes any gate or socket.
Every child is owned and reaped by Popen; never signal a PID after reaping it.
"""
import json
import os
from pathlib import Path
import signal
import select
import subprocess
import tempfile
import time

source = r'''
#import <AppKit/AppKit.h>
#include <signal.h>
int main() {
  @autoreleasepool {
    NSApplication *app = [NSApplication sharedApplication];
    [app setActivationPolicy:NSApplicationActivationPolicyProhibited];
    signal(SIGUSR1, SIG_IGN);
    dispatch_source_t quit = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGUSR1, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(quit, ^{ [app terminate:nil]; });
    dispatch_resume(quit);
    puts("ready"); fflush(stdout);
    [app run];
  }
}
'''


def sample(pid):
    r = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "lstart=", "-o", "comm="],
                       capture_output=True, text=True, timeout=1)
    try:
        os.kill(pid, 0)
        exists = True
    except ProcessLookupError:
        exists = False
    return r.returncode, r.stdout.strip(), exists


with tempfile.TemporaryDirectory(suffix=".noindex") as directory:
    root = Path(directory)
    binary = root / "GateQuitScratch.app/Contents/MacOS/VoiceBar"
    binary.parent.mkdir(parents=True)
    (root / "scratch.m").write_text(source)
    subprocess.run(["/usr/bin/clang", "-fblocks", "-framework", "AppKit", str(root / "scratch.m"), "-o", str(binary)], check=True)
    home = root / "home"
    home.mkdir()
    seen = set()
    for trial in range(20):
        child = subprocess.Popen([str(binary)], env={**os.environ, "HOME": str(home)}, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        try:
            if not select.select([child.stdout], [], [], 5)[0]:
                raise RuntimeError("scratch AppKit startup timed out")
            if child.stdout.readline().strip() != "ready":
                raise RuntimeError("scratch AppKit process failed startup")
            rc, pinned, exists = sample(child.pid)
            if rc != 0 or not exists or not pinned.endswith("/VoiceBar"):
                raise RuntimeError("scratch identity was not established")
            print(json.dumps(dict(trial=trial, pid=child.pid, pinned=pinned)), flush=True)
            os.kill(child.pid, signal.SIGUSR1)  # Only this scratch AppKit child.
            for tick in range(30):
                rc, current, exists = sample(child.pid)
                branch = "alive"
                if rc == 1 and not current and exists:
                    branch = "H1 identity throws: empty ps while pid exists"
                elif current != pinned and "<defunct>" not in current:
                    branch = "H1 identity mismatch"
                elif "<defunct>" in current:
                    branch = "same-birth defunct: old code already polls"
                key = (rc, current.split("2026")[-1], exists, branch)
                if key not in seen:
                    print(json.dumps(dict(trial=trial, tick=tick, rc=rc, identity=current, exists=exists, old_branch=branch)), flush=True)
                    seen.add(key)
                time.sleep(0.001)
            child.wait(timeout=2)
        finally:
            if child.poll() is None:
                child.kill()
                child.wait()
    print(json.dumps(dict(H2="No shared gate/lock touched", H3="No installed VoiceBar launched", classes=len(seen))), flush=True)
