"""Harness-only fixture ownership. Never used by the production orphan reaper."""
import atexit
import fcntl
import importlib.util
import json
import math
import os
from pathlib import Path
import secrets
import select
import signal
import stat
import subprocess
import sys
import time
import uuid


def diagnostic_output(command):
    """Keep arbitrary process bytes from interrupting diagnostic teardown."""
    return subprocess.run(command, capture_output=True).stdout.decode("utf-8", errors="replace")


def publish(path, value):
    """Publish a complete fixture readiness receipt."""
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(value)
    temporary.replace(path)


def metadata(pid):
    result = subprocess.run(['ps', '-p', str(pid), '-o', 'uid=,stat=,lstart='],
                            text=True, capture_output=True, env=dict(os.environ, LC_ALL='C', TZ='UTC'))
    fields = result.stdout.split()
    if len(fields) < 7 or fields[0] != str(os.getuid()) or 'Z' in fields[1]:
        return None
    return ' '.join(fields[2:])


# Stable harness-family identity: a sweep from any checkout may recover a run
# from a copied or deleted checkout, but only through an index entry that is
# token-bound to the run's own registry.
FAMILY = 'voicelayer-hook-fixture/1'


def liveness(pid, started):
    """'alive', 'dead' (proven gone or PID reused) or 'unknown'; never guess."""
    if type(pid) is not int or pid <= 1 or not started:
        return 'unknown'
    result = subprocess.run(['ps', '-p', str(pid), '-o', 'uid=,stat=,lstart='],
                            text=True, capture_output=True, env=dict(os.environ, LC_ALL='C', TZ='UTC'))
    fields = result.stdout.split()
    if not fields:
        return 'dead' if result.returncode == 1 and not result.stderr.strip() else 'unknown'
    if result.returncode != 0 or len(fields) < 7:
        return 'unknown'
    if ' '.join(fields[2:]) != started or 'Z' in fields[1]:
        return 'dead'
    return 'alive' if fields[0] == str(os.getuid()) else 'unknown'


def _private_dir(path):
    info = os.lstat(path)
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
        raise OSError(f'not a private directory: {path}')
    return path


def run_root(root):
    """The isolated root for scratch and the index; never /tmp and never adopted."""
    supplied = os.environ.get('VOICELAYER_TEST_RUN_ROOT', '').strip()
    if supplied:
        return _private_dir(Path(supplied))
    if os.environ.get('VOICELAYER_TEST_ISOLATED') == '1':
        raise SystemExit('VOICELAYER_TEST_RUN_ROOT is required for isolated (Bun) runs')
    tests = root / '.test-tmp'
    tests.mkdir(mode=0o700, exist_ok=True)
    _private_dir(tests)
    for _ in range(8):
        # Same <pid>-<nonce> shape as the Bun preload: exclusive, never adopted.
        candidate = tests / f'{os.getpid()}-{secrets.token_hex(2)}'
        try:
            candidate.mkdir(mode=0o700)
        except FileExistsError:
            continue
        os.environ['VOICELAYER_TEST_RUN_ROOT'] = str(candidate)
        return candidate
    raise SystemExit('could not create an exclusive test run root')


def index_dir(root):
    """Nested harnesses inherit the outermost index, which outlives X/Y checkouts."""
    inherited = os.environ.get('HOOK_FIXTURE_INDEX', '').strip()
    if inherited:
        return _private_dir(Path(inherited))
    index = run_root(root) / 'hook-fixtures'
    index.mkdir(mode=0o700, exist_ok=True)
    os.environ['HOOK_FIXTURE_INDEX'] = str(_private_dir(index))
    return index


_identity_readers = {}


def identities(root):
    key = str(root)
    if key in _identity_readers:
        return _identity_readers[key]
    spec = importlib.util.spec_from_file_location('fixture_identity', root / 'scripts/supervise-test-daemon.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    _identity_readers[key] = module.process_identity
    return module.process_identity


def register():
    """Publish under the same lock that closes registration before teardown."""
    base = Path(os.environ['HOOK_FIXTURE_RUN'])
    with (base / 'fixture-registration.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if (base / 'fixture-registration.closed').exists() or (base / 'fixture-cleanup.done').exists():
            raise SystemExit(75)
        pid = os.getpid()
        row = dict(pid=pid, started=metadata(pid), token=os.environ['HOOK_FIXTURE_TOKEN'])
        assert row['started']
        temporary = base / f'fixture-{pid}.tmp'
        temporary.write_text(json.dumps(row))
        temporary.replace(base / f'fixture-{pid}.json')


def exec_registered(argv, orphan=False):
    if orphan:
        if os.fork():
            os._exit(0)
        os.setsid()
    if os.environ.pop('HOOK_FIXTURE_REGISTRATION_GATE', None):
        print('REGISTRATION WAITING', flush=True)
        sys.stdin.buffer.read(1)
    register()
    os.execvpe(argv[0], argv, os.environ)


def spawn(argv, *, orphan=False, **kwargs):
    """The only fixture Popen: the child registers itself before executing argv."""
    env = dict(kwargs.pop('env', os.environ))
    env['HOOK_FIXTURE_BIRTH_RUN'] = env['HOOK_FIXTURE_RUN']
    env['HOOK_FIXTURE_BIRTH_TOKEN'] = env['HOOK_FIXTURE_TOKEN']
    return subprocess.Popen([sys.executable, __file__, '--orphan' if orphan else '--exec', *argv],
                            env=env, **kwargs)


def cleanup(base, root):
    with (base / 'fixture-registration.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        # A late child must observe this before it can exec any fixture payload.
        (base / 'fixture-registration.closed').touch()
        _cleanup_closed(base, root)


def _cleanup_closed(base, root):
    identity = identities(root)
    state = json.loads((base / 'fixture-registry.json').read_text())
    token = state['token']
    rows = []
    reported = set()
    def report(pid, reason):
        key = (str(pid), reason)
        if key in reported:
            return
        reported.add(key)
        with (base / 'fixture-cleanup.jsonl').open('a') as stream:
            stream.write(json.dumps(dict(pid=pid, reason=reason)) + '\n')
    def fixture_state(row):
        """Signal only alive identities; settle only positively dead identities."""
        pid = row.get('pid')
        if type(pid) is not int or pid <= 1 or not row.get('started') or row.get('token') != token:
            report(pid, 'unverifiable record; never signalled')
            return 'unknown'
        status = liveness(pid, row['started'])
        if status != 'alive':
            return status
        started = metadata(pid)
        if started is None:
            report(pid, 'unverifiable start; never signalled')
            return 'unknown'
        if started != row['started']:
            return 'dead'
        observed = identity(pid)
        if observed is None:
            report(pid, 'unreadable identity; never signalled')
            return 'unknown'
        owned = any(
            observed[1].get(run_key) == str(base) and observed[1].get(token_key) == token
            for run_key, token_key in (('HOOK_FIXTURE_RUN', 'HOOK_FIXTURE_TOKEN'),
                                       ('HOOK_FIXTURE_BIRTH_RUN', 'HOOK_FIXTURE_BIRTH_TOKEN')))
        if not owned:
            report(pid, 'identity mismatch or unreadable; never signalled')
            return 'unknown'
        return 'alive'
    unreadable = False
    for path in base.glob('fixture-*.json'):
        if path.name == 'fixture-registry.json':
            continue
        if path.is_symlink():
            unreadable = True
            report(None, 'symlink record; never read')
            continue
        try:
            row = json.loads(path.read_text())
            if not isinstance(row, dict):
                raise ValueError('non-object record')
            rows.append(row)
        except (OSError, ValueError):
            unreadable = True
            report(None, 'malformed record; never signalled')
    def send(row, signum):
        # Re-read start time AND the native environment before EACH individual signal.
        status = fixture_state(row)
        if status == 'alive':
            try:
                os.kill(row['pid'], signum)
                report(row['pid'], f'sent {int(signum)} after identity verification')
            except ProcessLookupError:
                pass
        return status
    # Keep original PID/start/token rows for the final fresh verification. Each
    # pending entry is that exact lifetime, never a PID-only signal authority.
    rows = tuple(rows)
    pending = [row for row in rows if send(row, signal.SIGTERM) != 'dead']
    def pending_states():
        nonlocal pending
        observed = [(row, fixture_state(row)) for row in pending]
        pending = [row for row, status in observed if status != 'dead']
        return [status for _, status in observed]
    deadline = time.monotonic() + .5
    while time.monotonic() < deadline and 'alive' in pending_states():
        time.sleep(.025)
    pending = [row for row in pending if send(row, signal.SIGKILL) != 'dead']
    settle_seconds = float(os.environ.get("HOOK_FIXTURE_SETTLE_DEADLINE_S", "3"))
    if not math.isfinite(settle_seconds) or settle_seconds <= 0:
        raise ValueError("HOOK_FIXTURE_SETTLE_DEADLINE_S must be finite and positive")
    deadline = time.monotonic() + settle_seconds
    while time.monotonic() < deadline and any(status != 'dead' for status in pending_states()):
        time.sleep(.025)
    remaining = [row.get('pid') for row in rows if fixture_state(row) != 'dead']
    if remaining or unreadable:
        # The index entry stays, so a later sweep retries with the same evidence.
        raise RuntimeError(f'fixture teardown unresolved: {remaining}; unreadable={unreadable}')
    (base / 'fixture-cleanup.done').touch()
    entry = state.get('index')
    if entry and not Path(entry).is_symlink():
        Path(entry).unlink(missing_ok=True)


def _indexes(root):
    found = []
    for candidate in (os.environ.get('HOOK_FIXTURE_INDEX', '').strip(),
                      os.environ.get('VOICELAYER_TEST_RUN_ROOT', '').strip() and
                      str(Path(os.environ['VOICELAYER_TEST_RUN_ROOT'].strip()) / 'hook-fixtures')):
        if candidate:
            found.append(Path(candidate))
    found.extend(sorted((root / '.test-tmp').glob('*/hook-fixtures')))
    unique = {}
    for index in found:
        try:
            unique.setdefault(os.path.realpath(_private_dir(index)), index)
        except OSError:
            continue
    return list(unique.values())


def sweep(root):
    """Recover runs from this checkout's stable isolated indexes, never a /tmp glob."""
    for index in _indexes(root):
        sweep_index(index, root)


def sweep_index(index, root):
    """Only indexed runs with a proven-dead owner AND no held owner lease."""
    for entry in sorted(index.glob('*.json')):
        base = None
        try:
            if entry.is_symlink() or not entry.is_file():
                continue
            pointer = json.loads(entry.read_text())
            if pointer.get('family') != FAMILY:
                continue
            base = Path(pointer['base'])
            if not base.is_absolute():
                raise ValueError('relative run path')
            try:
                _private_dir(base)
            except FileNotFoundError:
                # Nothing left to verify a signal against; the pointer alone is no authority.
                print(f'UNVERIFIABLE fixture run {base}: registry missing; never signalled', flush=True)
                entry.unlink(missing_ok=True)
                continue
            marker = base / 'fixture-registry.json'
            lock = base / 'fixture-owner.lock'
            if marker.is_symlink() or lock.is_symlink() or not marker.is_file() or not lock.is_file():
                continue
            state = json.loads(marker.read_text())
            if state.get('token') != pointer.get('token') or state.get('family') != FAMILY:
                continue
            if (base / 'fixture-cleanup.done').is_file() and (base / 'fixture-registration.closed').is_file():
                entry.unlink(missing_ok=True)
                continue
            with lock.open('r+') as lease:
                try:
                    fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    continue
                owner = state['owner']
                # An unreadable owner identity is not proof of death: keep the evidence.
                if liveness(owner['pid'], owner['started']) != 'dead':
                    continue
                # Serialize stale sweep with the surviving guardian.
                with (base / 'fixture-cleanup.lock').open('a') as serial:
                    fcntl.flock(serial, fcntl.LOCK_EX)
                    cleanup(base, root)
        except RuntimeError as error:
            print(f'UNRESOLVED fixture run {base or entry}: {error}; evidence retained', flush=True)
        except (OSError, ValueError, KeyError, TypeError) as error:
            print(f'UNVERIFIABLE fixture run {base or entry}: {type(error).__name__}; never signalled', flush=True)


def start(base, root, upstream=None):
    """upstream: the PID that launched the owner; its death also ends the run."""
    watched = ''
    if upstream is not None and upstream > 1:
        watched = metadata(upstream)
        # Re-check parentage after reading the start time, so a reused PID is never watched.
        if not watched or os.getppid() != upstream:
            raise SystemExit('fixture harness launcher already exited; refusing to start fixtures')
    token = uuid.uuid4().hex
    entry = index_dir(root) / f'{token}.json'
    owner = dict(pid=os.getpid(), started=metadata(os.getpid()))
    state = dict(family=FAMILY, harness=str(root.resolve()), base=str(base), index=str(entry),
                 token=token, owner=owner, upstream=dict(pid=upstream if watched else None, started=watched or None))
    (base / 'fixture-registry.json').write_text(json.dumps(state))
    # Index before any fixture can exist: a dead owner's run stays discoverable
    # even when its checkout is gone.
    temporary = entry.with_suffix('.tmp')
    temporary.write_text(json.dumps(dict(family=FAMILY, token=token, base=str(base), owner=owner)))
    temporary.replace(entry)
    os.environ.update(HOOK_FIXTURE_RUN=str(base), HOOK_FIXTURE_TOKEN=token)
    read_fd, write_fd = os.pipe()
    guardian = subprocess.Popen([sys.executable, __file__, str(base), str(root),
                                 str(upstream if watched else 0), watched], stdin=read_fd,
                                stdout=subprocess.DEVNULL, stderr=(base / 'fixture-guardian.log').open('a'),
                                start_new_session=True)
    (base / 'fixture-guardian.identity').write_text(json.dumps(dict(
        pid=guardian.pid, started=metadata(guardian.pid), token=token)))
    os.close(read_fd)
    atexit.register(finish, guardian, write_fd)
    deadline = time.monotonic() + 5
    while not (base / 'fixture-guardian.ready').exists():
        assert guardian.poll() is None and time.monotonic() < deadline, 'guardian failed to become ready'
        time.sleep(.01)
    return guardian, write_fd


_finished = set()


def finish(guardian, write_fd):
    key = (guardian.pid, write_fd)
    if key in _finished:
        return
    _finished.add(key)
    os.close(write_fd)
    assert guardian.wait(timeout=10) == 0, 'fixture guardian failed; evidence retained'


if __name__ == '__main__':
    if sys.argv[1] in ('--exec', '--orphan'):
        exec_registered(sys.argv[2:], orphan=sys.argv[1] == '--orphan')
    if sys.argv[1] == '--sweep-index':
        sweep_index(Path(sys.argv[2]), Path(sys.argv[3]))
        raise SystemExit(1 if any(Path(sys.argv[2]).glob('*.json')) else 0)
    base, root = map(Path, sys.argv[1:3])
    upstream, upstream_started = int(sys.argv[3]), sys.argv[4]
    # Load native identity code before allowing payloads to spawn: wrapper
    # checkouts can disappear on abort, but the guardian must remain independent.
    identities(root)
    (base / 'fixture-guardian.ready').touch()
    # Only the owner holds the write end. Unregistered launchers cannot exec
    # after EOF closes registration, including when stale cleanup wins the race.
    # Bounded polling also watches the owner's launcher: a SIGKILLed runner
    # forwards nothing and leaves the owner (and its lease) alive.
    ticks = 0
    while True:
        if select.select([0], [], [], .25)[0]:
            if not os.read(0, 4096):
                break
            continue
        if not upstream:
            continue
        ticks += 1
        try:
            os.kill(upstream, 0)
        except ProcessLookupError:
            reason = 'exited'
        except PermissionError:
            continue
        else:
            # Zombies and PID reuse need the start time; only proven death counts.
            if ticks % 8 or liveness(upstream, upstream_started) != 'dead':
                continue
            reason = 'exited or reused'
        print(f'fixture owner launcher {upstream} {reason}; closing registration', file=sys.stderr, flush=True)
        break
    with (base / 'fixture-cleanup.lock').open('a') as serial:
        fcntl.flock(serial, fcntl.LOCK_EX)
        cleanup(base, root)
