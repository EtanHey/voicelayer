"""Deterministic cleanup work counts and signal-boundary counterexamples."""
import collections
from contextlib import ExitStack
import json
import os
from pathlib import Path
import signal
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
import hook_fixture_registry as registry


class CleanupTests(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory(dir=os.environ.get('VOICELAYER_TEST_RUN_ROOT'))
        self.addCleanup(scratch.cleanup)
        self.base = Path(scratch.name)
        self.token = 'test-lifetime-token'
        self.entry = self.base / 'index-entry'
        self.entry.touch()
        (self.base / 'fixture-registry.json').write_text(json.dumps(
            dict(token=self.token, index=str(self.entry))))
        self.calls = collections.Counter()
        self.signals = []
        self.native_calls = collections.Counter()

    def row(self, pid, **changes):
        row = dict(pid=pid, started='original-start', token=self.token)
        row.update(changes)
        (self.base / f'fixture-{pid}.json').write_text(json.dumps(row))
        return row

    def owned(self, pid):
        self.native_calls[pid] += 1
        return ('fixture', dict(HOOK_FIXTURE_RUN=str(self.base), HOOK_FIXTURE_TOKEN=self.token))

    def run_cleanup(self, live, native=None, metadata=None):
        def liveness(pid, started):
            self.calls[pid] += 1
            self.assertEqual(started, 'original-start')
            return live(pid, self.calls[pid])

        def kill(pid, signum):
            # Every signal must immediately follow a new complete native check.
            prior = sum(p == pid for p, _ in self.signals)
            self.assertGreater(self.native_calls[pid], prior)
            self.signals.append((pid, signum))

        ticks = iter(i / 4 for i in range(1000))
        with ExitStack() as stack:
            stack.enter_context(patch.object(registry, 'identities', return_value=native or self.owned))
            stack.enter_context(patch.object(registry, 'liveness', side_effect=liveness))
            stack.enter_context(patch.object(registry, 'metadata', side_effect=metadata or (lambda _: 'original-start')))
            stack.enter_context(patch.object(registry.os, 'kill', side_effect=kill))
            stack.enter_context(patch.object(registry.time, 'monotonic', side_effect=lambda: next(ticks)))
            stack.enter_context(patch.object(registry.time, 'sleep'))
            registry.cleanup(self.base, self.base)

    def test_many_dead_few_stubborn_live_keep_final_every_row_check(self):
        for pid in range(100, 264):
            self.row(pid)
        original = {p.name: p.read_bytes() for p in self.base.glob('fixture-*.json')}

        def live(pid, count):
            if pid < 253:
                return 'dead'
            return 'dead' if (pid, signal.SIGKILL) in self.signals else 'alive'

        self.run_cleanup(live)
        self.assertEqual({self.calls[p] for p in range(100, 253)}, {2},
                         '153 dead lifetimes need only initial and final checks')
        self.assertEqual(len(self.signals), 22)
        for pid in range(253, 264):
            self.assertEqual([s for p, s in self.signals if p == pid],
                             [signal.SIGTERM, signal.SIGKILL])
        self.assertTrue(all(self.calls[p] >= 4 for p in range(253, 264)))
        self.assertEqual(original, {p.name: p.read_bytes() for p in self.base.glob('fixture-*.json')})
        self.assertTrue((self.base / 'fixture-cleanup.done').exists())
        self.assertFalse(self.entry.exists())
        print(f'CAUSAL 153 dead rows: {sum(self.calls[p] for p in range(100, 253))} checks; '
              f'11 stubborn live rows: {len(self.signals)} freshly verified signals', flush=True)

    def test_final_inspection_bypasses_intermediate_dead_removal(self):
        self.row(100)
        with self.assertRaisesRegex(RuntimeError, 'unresolved'):
            # Even a later unknown must be noticed by the final all-row pass.
            self.run_cleanup(lambda pid, count: 'dead' if count == 1 else 'unknown')
        self.assertEqual(self.calls[100], 2)
        self.assertEqual(self.signals, [])
        self.assertTrue(self.entry.exists())
        self.assertFalse((self.base / 'fixture-cleanup.done').exists())

    def test_unknown_unreadable_mismatched_and_invalid_remain_refused(self):
        for pid in range(100, 105):
            self.row(pid)
        self.row(105, token='foreign-token')
        self.row(106, started=None)
        (self.base / 'fixture-malformed.json').write_text('{')
        (self.base / 'fixture-symlink.json').symlink_to(self.base / 'fixture-100.json')

        def native(pid):
            if pid == 101:
                return None
            return ('foreign', {})

        with self.assertRaisesRegex(RuntimeError, 'unreadable=True'):
            self.run_cleanup(lambda pid, count: 'unknown' if pid == 100 else 'alive',
                             native=native, metadata=lambda pid: None if pid == 103 else 'original-start')
        self.assertEqual(self.signals, [])
        self.assertTrue(all(self.calls[p] >= 3 for p in range(100, 105)))
        self.assertEqual(self.calls[105], 0)
        self.assertEqual(self.calls[106], 0)
        self.assertTrue(self.entry.exists())
        self.assertFalse((self.base / 'fixture-cleanup.done').exists())

    def test_pid_reuse_after_dead_observation_never_signals_new_lifetime(self):
        self.row(100)
        # liveness positively proves the original start gone; final verification
        # still checks it. A same-PID foreign successor grants no authority.
        self.run_cleanup(lambda pid, count: 'dead')
        self.assertEqual(self.calls[100], 2)
        self.assertEqual(self.native_calls[100], 0)
        self.assertEqual(self.signals, [])

    def test_pid_reuse_between_liveness_and_metadata_refuses_signal(self):
        self.row(100)
        self.run_cleanup(lambda pid, count: 'alive', metadata=lambda pid: 'reused-start')
        self.assertEqual(self.calls[100], 2)
        self.assertEqual(self.native_calls[100], 0)
        self.assertEqual(self.signals, [])

    def test_native_token_change_after_term_refuses_kill(self):
        self.row(100)

        def native(pid):
            observed = self.owned(pid)
            return ('foreign', {}) if self.signals else observed

        with self.assertRaisesRegex(RuntimeError, 'unresolved'):
            self.run_cleanup(lambda pid, count: 'alive', native=native)
        self.assertEqual(self.signals, [(100, signal.SIGTERM)])
        self.assertGreaterEqual(self.native_calls[100], 3)
        self.assertTrue(self.entry.exists())


if __name__ == '__main__':
    unittest.main(verbosity=2)
