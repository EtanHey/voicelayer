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
sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tests'))
import hook_fixture_registry as registry
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
