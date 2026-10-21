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


def launch(args=None):
    child = subprocess.Popen(['bash', str(root / 'tests/test_hook_orphan_daemon.sh'), *(args or ['--abort-fixture-check'])],
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                             start_new_session=True)
    base = None
    for line in child.stdout:
        if line.startswith('HOOK evidence: '):
            base = Path(line.strip().split(': ', 1)[1])
        if line.startswith('ABORT READY'):
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


def kill_guardian(base):
    saved = json.loads((base / 'fixture-guardian.identity').read_text())
    assert registry.metadata(saved['pid']) == saved['started']
    observed = registry.identities(root)(saved['pid'])
    assert observed[1]['HOOK_FIXTURE_TOKEN'] == saved['token']
    os.kill(saved['pid'], signal.SIGKILL)


def survivors(base):
    read_identity = registry.identities(root)
    rows = subprocess.check_output(['ps', '-ax', '-o', 'pid=,uid=,stat='], text=True)
    result = []
    for line in rows.splitlines():
        fields = line.split()
        if len(fields) != 3 or fields[1] != str(os.getuid()) or 'Z' in fields[2]:
            continue
        pid = int(fields[0])
        observed = read_identity(pid)
        if observed and any(observed[1].get(key) == str(base) for key in (
                'HOOK_FIXTURE_RUN', 'HOOK_FIXTURE_BIRTH_RUN')):
            result.append(pid)
    return result


# The actual pre-exec launcher is paused before registration. The owner AND
# guardian die; stale cleanup closes registration, then the launcher resumes.
child, base = launch()
state = json.loads((base / 'fixture-registry.json').read_text())
env = dict(os.environ, HOOK_FIXTURE_RUN=str(base), HOOK_FIXTURE_TOKEN=state['token'],
           HOOK_FIXTURE_REGISTRATION_GATE='1')
late = registry.spawn([sys.executable, '-c', 'raise SystemExit("payload must never exec")'],
                      env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
try:
    assert late.stdout.readline().strip() == 'REGISTRATION WAITING'
    kill_guardian(base)
    child.kill()
    child.wait(timeout=5)
    registry.sweep(root)
    assert (base / 'fixture-cleanup.done').exists()
    assert (base / 'fixture-registration.closed').exists()
    late.stdin.write('x')
    late.stdin.flush()
    assert late.wait(timeout=5) == 75, 'late launcher executed after closure'
    registry.sweep(root)
    assert not survivors(base), f'late registration survivors: {survivors(base)}'
    print('PASS late registration: stale sweep closes registration before completion; late exec refused', flush=True)
finally:
    late.stdin.close()
    if late.poll() is None:
        # Closing the gate on EOF lets the same register/closed check settle it.
        late.wait(timeout=5)
    if child.poll() is None:
        child.kill()
        child.wait(timeout=5)


for point in ('KILL-supervisor', 'KILL-group', 'KILL-swift-build', 'KILL-group-swift-build',
              'KILL-swift-test', 'KILL', 'KILL-late'):
    child, base = launch(['--abort-lifecycle-check', point])
    try:
        # Readiness is emitted by the FULL harness after reaching the actual
        # lifecycle point, with its negatives, runner and real supervisor active.
        child.kill()
        child.wait(timeout=5)
        assert wait(lambda: not survivors(base), 15), f'{point}: survivors {survivors(base)}'
        assert (base / 'fixture-registration.closed').exists()
        # The guardian may retain an unreadable/re-exec identity that exits later.
        # Recover this run after death is proven instead of assuming one pass settles it.
        def settled():
            registry.sweep_index(Path(json.loads((base / 'fixture-registry.json').read_text())['index']).parent, root)
            return (base / 'fixture-cleanup.done').exists()
        assert wait(settled), 'cleanup did not settle'
        print(f'PASS full-harness abort {point}: zero run-tagged survivors', flush=True)
    finally:
        if child.poll() is None:
            child.kill()
            child.wait(timeout=5)
