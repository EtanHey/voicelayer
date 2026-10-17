"""Abort real escape fixtures; teardown authority never includes an unrelated sentinel."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

root = Path(sys.argv[1])
sys.dont_write_bytecode = True
os.environ["PYTHONDONTWRITEBYTECODE"] = "1"
sys.path.insert(0, str(root / 'tests'))
import hook_fixture_registry as registry


def wait(predicate, seconds=8):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(.025)
    return False


def launch():
    child = subprocess.Popen(['bash', str(root / 'tests/test_hook_orphan_daemon.sh'), '--abort-fixture-check'],
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                             start_new_session=True)
    base = None
    for line in child.stdout:
        if line.startswith('HOOK evidence: '):
            base = Path(line.strip().split(': ', 1)[1])
        if line.strip() == 'ABORT READY':
            return child, base
    raise AssertionError(f'fixture failed to start: {child.wait()}')


# Unrelated process has neither the registry nonce nor the harness environment.
# Persist its real PID and real start time to prove that those alone are insufficient.
sentinel = subprocess.Popen([sys.executable, '-c', 'import sys; sys.stdin.buffer.read()'], stdin=subprocess.PIPE)
try:
    for mode in ('INT', 'TERM', 'KILL', 'timeout', 'assertion', 'stale'):
        child, base = launch()
        fixture_pid = int((base / 'symlink-escape.pid').read_text())
        fixture_row = json.loads((base / f'fixture-{fixture_pid}.json').read_text())
        state = json.loads((base / 'fixture-registry.json').read_text())
        (base / f'fixture-{sentinel.pid}.json').write_text(json.dumps(dict(
            pid=sentinel.pid, started=registry.metadata(sentinel.pid), token=state['token'])))
        # Wrong start time must also fail even for an otherwise matching fixture.
        forged = dict(fixture_row, started='stale start time')
        (base / 'fixture-forged.json').write_text(json.dumps(forged))
        if mode == 'stale':
            # Kill just the separately recorded guardian, then its owner. Startup
            # recovery must work even when the guardian itself could not finish.
            guardian = json.loads((base / 'fixture-guardian.identity').read_text())
            guardian_pid = guardian['pid']
            assert registry.metadata(guardian_pid) == guardian['started']
            assert registry.identities(root)(guardian_pid)[1]['HOOK_FIXTURE_TOKEN'] == guardian['token']
            os.kill(guardian_pid, signal.SIGKILL)
            child.kill()
        elif mode == 'timeout':
            try:
                child.wait(timeout=.05)
            except subprocess.TimeoutExpired:
                child.kill()
        elif mode == 'assertion':
            # Ask the harness to fail in its own try/finally, rather than in this driver.
            (base / 'fail-assertion').touch()
        else:
            child.send_signal(getattr(signal, 'SIG' + mode))
        child.wait(timeout=10)
        if mode == 'stale':
            result = subprocess.run(['bash', str(root / 'tests/test_hook_orphan_daemon.sh'), '--policy-check'],
                                    text=True, capture_output=True, timeout=15)
            assert result.returncode == 0, result.stdout + result.stderr
        assert wait(lambda: registry.metadata(fixture_pid) is None), f'{mode}: escape fixture leaked'
        assert sentinel.poll() is None, f'{mode}: non-fixture signalled'
        receipt = (base / 'fixture-cleanup.jsonl').read_text()
        assert 'sent 15 after identity verification' in receipt, receipt
        assert 'sent 9 after identity verification' in receipt, receipt
        assert 'identity mismatch or unreadable; never signalled' in receipt, receipt
        print(f'PASS {mode}: escape fixture reaped; forged identity and unrelated PID refused', flush=True)
finally:
    sentinel.stdin.close()
    sentinel.wait(timeout=5)
