"""Harness-only fixture ownership. Never used by the production orphan reaper."""
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
import uuid


def metadata(pid):
    result = subprocess.run(['ps', '-p', str(pid), '-o', 'uid=,stat=,lstart='],
                            text=True, capture_output=True, env=dict(os.environ, LC_ALL='C', TZ='UTC'))
    fields = result.stdout.split()
    if len(fields) < 7 or fields[0] != str(os.getuid()) or 'Z' in fields[1]:
        return None
    return ' '.join(fields[2:])


def identities(root):
    spec = importlib.util.spec_from_file_location('fixture_identity', root / 'scripts/supervise-test-daemon.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.process_identity


def register():
    """Called by the actual fixture before publishing its ready PID, including after fork."""
    base = Path(os.environ['HOOK_FIXTURE_RUN'])
    pid = os.getpid()
    row = dict(pid=pid, started=metadata(pid), token=os.environ['HOOK_FIXTURE_TOKEN'])
    assert row['started']
    temporary = base / f'fixture-{pid}.tmp'
    temporary.write_text(json.dumps(row))
    temporary.replace(base / f'fixture-{pid}.json')


def cleanup(base, root):
    identity = identities(root)
    token = json.loads((base / 'fixture-registry.json').read_text())['token']
    rows = []
    reported = set()
    def report(pid, reason):
        key = (str(pid), reason)
        if key in reported:
            return
        reported.add(key)
        with (base / 'fixture-cleanup.jsonl').open('a') as stream:
            stream.write(json.dumps(dict(pid=pid, reason=reason)) + '\n')
    def matches(row):
        pid = row.get('pid')
        if type(pid) is not int or pid <= 1 or not row.get('started') or row.get('token') != token:
            report(pid, 'unverifiable record; never signalled')
            return False
        started = metadata(pid)
        if started is None:
            report(pid, 'exited or unverifiable start; never signalled')
            return False
        observed = identity(pid)
        if started != row['started'] or observed is None or any(observed[1].get(k) != v for k, v in (
                ('HOOK_FIXTURE_RUN', str(base)), ('HOOK_FIXTURE_TOKEN', token))):
            report(pid, 'identity mismatch or unreadable; never signalled')
            return False
        return True
    for path in base.glob('fixture-*.json'):
        if path.name == 'fixture-registry.json':
            continue
        if path.is_symlink():
            report(None, 'symlink record; never read')
            continue
        try:
            row = json.loads(path.read_text())
            if not isinstance(row, dict):
                raise ValueError('non-object record')
            rows.append(row)
        except (OSError, ValueError):
            report(None, 'malformed record; never signalled')
    def send(row, signum):
        # Re-read start time AND the native environment before EACH individual signal.
        if matches(row):
            try:
                os.kill(row['pid'], signum)
                report(row['pid'], f'sent {int(signum)} after identity verification')
            except ProcessLookupError:
                pass
    for row in rows:
        send(row, signal.SIGTERM)
    deadline = time.monotonic() + .5
    while time.monotonic() < deadline and any(matches(row) for row in rows):
        time.sleep(.025)
    for row in rows:
        send(row, signal.SIGKILL)
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline and any(matches(row) for row in rows):
        time.sleep(.025)
    remaining = [row['pid'] for row in rows if matches(row)]
    if remaining:
        raise RuntimeError(f'fixture teardown survivors: {remaining}')
    (base / 'fixture-cleanup.done').touch()


def sweep(root):
    """Only our private run directories, with a dead owner AND no held owner lease."""
    harness = str(root.resolve())
    for base in Path('/tmp').glob('vlho-*'):
        try:
            if base.is_symlink() or base.stat().st_uid != os.getuid():
                continue
            marker = base / 'fixture-registry.json'
            lock = base / 'fixture-owner.lock'
            if marker.is_symlink() or lock.is_symlink() or not marker.is_file() or not lock.is_file():
                continue
            state = json.loads(marker.read_text())
            if (base / 'fixture-cleanup.done').is_file():
                continue
            if state.get('harness') != harness:
                continue
            with lock.open('r+') as lease:
                try:
                    fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    continue
                owner = state['owner']
                if metadata(owner['pid']) == owner['started']:
                    continue
                # Serialize stale sweep with the surviving guardian.
                with (base / 'fixture-cleanup.lock').open('a') as serial:
                    fcntl.flock(serial, fcntl.LOCK_EX)
                    cleanup(base, root)
        except (OSError, ValueError, KeyError, TypeError) as error:
            print(f'UNVERIFIABLE fixture run {base}: {type(error).__name__}; never signalled', flush=True)


def start(base, root):
    token = uuid.uuid4().hex
    state = dict(harness=str(root.resolve()), token=token,
                 owner=dict(pid=os.getpid(), started=metadata(os.getpid())))
    (base / 'fixture-registry.json').write_text(json.dumps(state))
    os.environ.update(HOOK_FIXTURE_RUN=str(base), HOOK_FIXTURE_TOKEN=token)
    read_fd, write_fd = os.pipe()
    guardian = subprocess.Popen([sys.executable, __file__, str(base), str(root)], stdin=read_fd,
                                stdout=subprocess.DEVNULL, stderr=(base / 'fixture-guardian.log').open('a'),
                                start_new_session=True)
    (base / 'fixture-guardian.identity').write_text(json.dumps(dict(
        pid=guardian.pid, started=metadata(guardian.pid), token=token)))
    os.close(read_fd)
    os.environ['HOOK_FIXTURE_FD'] = str(write_fd)
    return guardian, write_fd


if __name__ == '__main__':
    base, root = map(Path, sys.argv[1:])
    # Only the harness and still-starting fixture launchers hold the write end.
    # EOF covers success, assertions, signals, subprocess timeouts and SIGKILL.
    while os.read(0, 4096):
        pass
    with (base / 'fixture-cleanup.lock').open('a') as serial:
        fcntl.flock(serial, fcntl.LOCK_EX)
        cleanup(base, root)
