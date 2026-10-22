"""Real cross-wrapper abort matrix plus stale-sweep boundaries; Python, no audio."""
import fcntl
import os
import json
import shutil
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
import uuid
from unittest.mock import patch
sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tests'))
import hook_fixture_registry as registry
# Integration cases assert ownership and cleanup, not the settle wait.
os.environ["HOOK_FIXTURE_SETTLE_DEADLINE_S"] = "0.5"
identity = registry.identities(ROOT)


def wait(predicate, seconds=20):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        if predicate():
            return True
        time.sleep(.1)
    return False


def members(owner):
    found = {}
    for row in subprocess.check_output(['ps', '-ax', '-o', 'pid=,uid=,stat='], text=True).splitlines():
        f = row.split()
        if len(f) != 3 or f[1] != str(os.getuid()) or 'Z' in f[2]:
            continue
        pid = int(f[0])
        observed = identity(pid)
        if observed and observed[1].get('HOOK_TREE_PID') == str(owner):
            found[pid] = (registry.metadata(pid), observed[1]['HOOK_TREE_TOKEN'])
    return found


def teardown(child):
    owned = members(child.pid)
    if child.poll() is None:
        child.kill()
    child.wait(timeout=5)
    tokens = {saved[1] for saved in owned.values()}
    def reap():
        current = members(child.pid)
        for pid, (started, token) in current.items():
            observed = identity(pid)
            if token in tokens and started and registry.metadata(pid) == started and observed and observed[1].get('HOOK_TREE_TOKEN') == token:
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
        return not members(child.pid)
    assert wait(reap, 12), 'test teardown leaked'



class AbortCrossRun(unittest.TestCase):
    def test_dead_copied_root_is_recoverable_from_real_root(self):
        (ROOT / '.test-tmp').mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='fixtreap1-copy-', dir=ROOT / '.test-tmp') as tmp:
            checkout = Path(tmp) / 'X'
            for folder, files in [('tests', ['test_hook_orphan_daemon.sh', 'hook_fixture_registry.py', 'hook-term-sender.c']),
                                  ('scripts', ['supervise-test-daemon.py'])]:
                (checkout / folder).mkdir(parents=True)
                for name in files:
                    shutil.copy(ROOT / folder / name, checkout / folder / name)
            with open(Path(tmp) / 'output.log', 'w+') as log:
                child = subprocess.Popen(['bash', str(checkout / 'tests/test_hook_orphan_daemon.sh'), '--abort-fixture-check'],
                    env=dict(os.environ, PYTHONDONTWRITEBYTECODE='1', VOICELAYER_TEST_RUN_ROOT=tmp),
                    stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
                def ready():
                    log.seek(0)
                    return 'ABORT READY' in log.read()
                try:
                    self.assertTrue(wait(ready))
                    log.seek(0)
                    base = Path(next(line.split(': ', 1)[1].strip() for line in log if line.startswith('HOOK evidence: ')))
                    fixture = int((base / 'symlink-escape.pid').read_text())
                    guardian = json.loads((base / 'fixture-guardian.identity').read_text())
                    self.assertEqual(registry.metadata(guardian['pid']), guardian['started'])
                    self.assertEqual(identity(guardian['pid'])[1]['HOOK_FIXTURE_TOKEN'], guardian['token'])
                    os.kill(guardian['pid'], signal.SIGKILL)
                    child.kill()
                    child.wait(timeout=5)
                    # The copied checkout disappears too; the indexed registry must not.
                    shutil.rmtree(checkout)
                    registry.sweep(ROOT)
                    gone = wait(lambda: registry.metadata(fixture) is None, 8)
                    print(f'copied-root stale sweep: fixture_survives={not gone}', flush=True)
                    self.assertTrue(gone, 'real-root sweep skips dead copied-checkout registry')
                finally:
                    teardown(child)

    def test_abort_matrix_and_live_peer(self):
        failures = []
        (ROOT / '.test-tmp').mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='fixtreap1-', dir=ROOT / '.test-tmp') as isolated:
            env = dict(os.environ, PYTHONDONTWRITEBYTECODE='1', VOICELAYER_TEST_RUN_ROOT=isolated, HOOK_KEEP_EVIDENCE='1')
            def launch(log, mode):
                return subprocess.Popen(['bash', str(ROOT / 'tests/test_hook_orphan_daemon.sh'), mode],
                    env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            with open(Path(isolated) / 'peer.log', 'w+') as peerlog:
                peer = launch(peerlog, '--abort-fixture-check')
                def peer_ready():
                    peerlog.seek(0)
                    return 'ABORT READY' in peerlog.read()
                try:
                    self.assertTrue(wait(peer_ready), 'peer not ready')
                    protected = members(peer.pid)
                    self.assertTrue(protected)
                    for mode in ('TERM', 'INT', 'KILL'):
                        with open(Path(isolated) / (mode + '.log'), 'w+') as log:
                            pidfile = Path(isolated) / (mode + '.pid')
                            runner = subprocess.Popen([sys.executable, '-c',
                                "import pathlib,subprocess,sys; p=subprocess.Popen(sys.argv[2:]); pathlib.Path(sys.argv[1]).write_text(str(p.pid)); p.wait()",
                                str(pidfile), 'bash', str(ROOT / 'tests/test_hook_orphan_daemon.sh'), '--cross-run'],
                                env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
                            self.assertTrue(wait(pidfile.exists))
                            harness_pid = int(pidfile.read_text())
                            harness_start = registry.metadata(harness_pid)
                            class Harness:
                                pid = harness_pid
                                def poll(self):
                                    return None if registry.metadata(self.pid) == harness_start else 0
                                def kill(self):
                                    if self.poll() is None:
                                        os.kill(self.pid, signal.SIGKILL)
                                def wait(self, timeout):
                                    assert wait(lambda: self.poll() is not None, timeout)
                            child = Harness()
                            try:
                                def ready():
                                    lanes = set()
                                    for pid in members(child.pid):
                                        observed = identity(pid)
                                        if observed and any('import ctypes, os, pathlib' in arg for arg in observed[0]):
                                            lanes.add(observed[1].get('HOOK_CROSS_RUN_LANE'))
                                    return {'X', 'Y'} <= lanes
                                self.assertTrue(wait(ready, 45), f'{mode}: cross-run not ready')
                                runner.send_signal(getattr(signal, 'SIG' + mode))
                                runner.wait(timeout=5)
                                gone = wait(lambda: not members(child.pid), 8)
                                remaining = members(child.pid)
                                print(f'{mode}: survivors after 8s={len(remaining)} runner_exit={runner.poll()}', flush=True)
                                if not gone:
                                    failures.append(f'{mode}: {len(remaining)} run-tagged processes survive abort')
                                self.assertTrue(all(registry.metadata(pid) == saved[0] for pid, saved in protected.items()), 'live peer touched')
                                print(f'PASS {mode}: concurrent live peer unchanged', flush=True)
                            finally:
                                teardown(child)
                                if runner.poll() is None:
                                    runner.kill()
                                runner.wait(timeout=5)
                finally:
                    peer.kill()
                    peer.wait(timeout=5)
                    self.assertTrue(wait(lambda: not members(peer.pid), 12), 'peer cleanup failed')
        self.assertEqual(failures, [], '\n'.join(failures))


class StaleSweepBoundary(unittest.TestCase):
    """Index entries are swept only for a proven-dead owner with a free lease."""

    def setUp(self):
        (ROOT / '.test-tmp').mkdir(exist_ok=True)
        self.tmp = Path(tempfile.mkdtemp(prefix='fixtreap1-unit-', dir=ROOT / '.test-tmp'))
        self.index = self.tmp / 'hook-fixtures'
        self.index.mkdir()

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def fabricate(self, started, pid=None, family=registry.FAMILY):
        base = Path(tempfile.mkdtemp(prefix='vlho-unit-', dir=self.tmp))
        token = uuid.uuid4().hex
        entry = self.index / f'{token}.json'
        owner = dict(pid=pid or os.getpid(), started=started)
        (base / 'fixture-registry.json').write_text(json.dumps(dict(
            family=family, base=str(base), index=str(entry), token=token, owner=owner)))
        (base / 'fixture-owner.lock').write_text('')
        entry.write_text(json.dumps(dict(family=family, token=token, base=str(base), owner=owner)))
        return base, entry

    def swept(self, base, entry):
        registry.sweep_index(self.index, ROOT)
        closed = (base / 'fixture-registration.closed').exists()
        self.assertEqual(closed, (base / 'fixture-cleanup.done').exists())
        self.assertEqual(closed, not entry.exists(), 'index entry must outlive an unswept run')
        return closed

    def unknown_fixture(self, missing):
        base, entry = self.fabricate('Thu Jan  1 00:00:00 1970')
        token = json.loads((base / 'fixture-registry.json').read_text())['token']
        child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'],
            env=dict(os.environ, HOOK_FIXTURE_RUN=str(base), HOOK_FIXTURE_TOKEN=token))
        try:
            started = registry.metadata(child.pid)
            self.assertIsNotNone(started)
            (base / f'fixture-{child.pid}.json').write_text(json.dumps(dict(pid=child.pid, started=started, token=token)))
            target = 'identities' if missing == 'native' else 'metadata'
            replacement = (lambda root: lambda pid: None) if missing == 'native' else (lambda pid: None)
            with patch.object(registry, target, replacement), patch.object(registry.os, 'kill') as signals:
                try:
                    registry.cleanup(base, ROOT)
                except RuntimeError:
                    pass
                self.assertFalse((base / 'fixture-cleanup.done').exists())
                self.assertTrue(entry.exists())
                signals.assert_not_called()
                self.assertIsNone(child.poll())
            registry.sweep_index(self.index, ROOT)
            child.wait(timeout=5)
            self.assertTrue((base / 'fixture-cleanup.done').exists())
            self.assertFalse(entry.exists())
        finally:
            if child.poll() is None:
                child.kill()
            child.wait(timeout=5)

    def post_kill_unknown(self, transient):
        base, entry = self.fabricate('old owner')
        token = json.loads((base / 'fixture-registry.json').read_text())['token']
        (base / 'fixture-1234567.json').write_text(json.dumps(dict(
            pid=1234567, started='fixture start', token=token)))
        # A separate cleanup process exercises its actual exit status. Its clock and
        # signals are controlled: no real PID is ever inspected or signalled.
        code = """
import json, pathlib, signal, sys
from unittest.mock import patch
sys.path.insert(0, str(pathlib.Path.cwd() / 'tests'))
import hook_fixture_registry as registry
base, transient = pathlib.Path(sys.argv[1]), sys.argv[2] == 'True'
token = json.loads((base / 'fixture-registry.json').read_text())['token']
clock = [0.0]
killed_at = [None]
signals = []
def sleep(seconds):
    clock[0] += seconds
def liveness(pid, started):
    if killed_at[0] is None:
        return 'alive'
    return 'dead' if transient and clock[0] - killed_at[0] >= .1 else 'unknown'
def kill(pid, signum):
    assert liveness(pid, '') == 'alive', 'unknown identity was signalled'
    signals.append(int(signum))
    if signum == signal.SIGKILL:
        killed_at[0] = clock[0]
observed = ([], dict(HOOK_FIXTURE_RUN=str(base), HOOK_FIXTURE_TOKEN=token))
try:
    with patch.object(registry.time, 'monotonic', lambda: clock[0]), \
         patch.object(registry.time, 'sleep', sleep), \
         patch.object(registry, 'liveness', liveness), \
         patch.object(registry, 'metadata', lambda pid: 'fixture start'), \
         patch.object(registry, 'identities', lambda root: lambda pid: observed), \
         patch.object(registry.os, 'kill', kill):
        registry.cleanup(base, pathlib.Path.cwd())
finally:
    (base / 'settle-observation.json').write_text(json.dumps(dict(
        elapsed=clock[0] - killed_at[0], signals=signals)))
"""
        # Both controlled-clock regressions exercise the real default deadline.
        settle_env = dict(os.environ)
        settle_env.pop("HOOK_FIXTURE_SETTLE_DEADLINE_S", None)
        result = subprocess.run([sys.executable, '-B', '-c', code, str(base), str(transient)],
                                env=settle_env, capture_output=True, text=True)
        observation = json.loads((base / 'settle-observation.json').read_text())
        self.assertEqual(observation['signals'], [int(signal.SIGTERM), int(signal.SIGKILL)])
        if transient:
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertGreaterEqual(observation['elapsed'], .1)
            self.assertTrue((base / 'fixture-cleanup.done').exists())
            self.assertFalse(entry.exists())
        else:
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('fixture teardown unresolved', result.stderr)
            self.assertGreaterEqual(observation['elapsed'], 3)
            self.assertFalse((base / 'fixture-cleanup.done').exists())
            self.assertTrue(entry.exists())

    def test_post_kill_transient_unknown_settles_before_deadline(self):
        self.post_kill_unknown(True)

    def test_post_kill_persistent_unknown_retains_evidence_after_deadline(self):
        self.post_kill_unknown(False)

    def test_unknown_native_fixture_identity_retains_index(self):
        self.unknown_fixture('native')

    def test_unavailable_fixture_start_retains_index(self):
        self.unknown_fixture('start')

    def test_live_owner_is_never_swept(self):
        self.assertFalse(self.swept(*self.fabricate(registry.metadata(os.getpid()))))

    def test_reused_owner_pid_is_dead(self):
        self.assertTrue(self.swept(*self.fabricate('Thu Jan  1 00:00:00 1970')))

    def test_unreadable_owner_identity_retains_evidence(self):
        run = self.fabricate('Thu Jan  1 00:00:00 1970')
        original = registry.liveness
        registry.liveness = lambda pid, started: 'unknown'
        try:
            self.assertFalse(self.swept(*run))
        finally:
            registry.liveness = original

    def test_held_owner_lease_protects_dead_looking_owner(self):
        base, entry = self.fabricate('Thu Jan  1 00:00:00 1970')
        with (base / 'fixture-owner.lock').open('r+') as lease:
            fcntl.flock(lease, fcntl.LOCK_EX)
            self.assertFalse(self.swept(base, entry))
        self.assertTrue(self.swept(base, entry))

    def test_token_or_family_mismatch_is_never_swept(self):
        base, entry = self.fabricate('Thu Jan  1 00:00:00 1970', family='other')
        self.assertFalse(self.swept(base, entry))
        base, entry = self.fabricate('Thu Jan  1 00:00:00 1970')
        entry.write_text(json.dumps(dict(json.loads(entry.read_text()), token=uuid.uuid4().hex)))
        self.assertFalse(self.swept(base, entry))


if __name__ == '__main__':
    unittest.main()
