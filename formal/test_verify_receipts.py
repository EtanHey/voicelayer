"""Small synthetic receipts exercise freshness and exact-property validation; no TLC."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('verifier', Path(__file__).with_name('verify-receipts.py'))
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)


class ReceiptTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.model = self.root / 'formal/example'
        self.model.mkdir(parents=True)
        self.manifest = dict(module='Example', sources=['source.ts'], acceptance=['Safe'], checks={
            'Fixed': dict(role='positive', kind='pass', target=None),
            'Liveness': dict(role='positive', kind='pass', target=None),
            'MutSafe': dict(role='mutant', kind='invariant', target='Safe')})
        (self.model / 'checks.json').write_text(json.dumps(self.manifest))
        (self.model / 'check.sh').touch()
        (self.root / 'formal/tlc.lock.json').write_text('{"sha256":"pin"}')
        for name in self.manifest['checks']:
            (self.model / (name + '.cfg')).touch()
        paths = verifier.tracked_files(self.model, self.root, self.manifest)
        for path in paths:
            if not path.exists():
                path.write_text('fixture')
        self.receipt = dict(complete=True, tlcJarSHA256='pin',
            hashes={str(p.relative_to(self.root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths},
            mutants={'Safe': ['MutSafe']}, checks={name: dict(**row, status='EXPECTED_FAIL' if row['target'] else 'PASS') for name, row in self.manifest['checks'].items()})
        self.save()
        self.write_workflow()

    def write_workflow(self, push_scripts=False, pr_scripts=False):
        workflow = self.root / '.github/workflows/formal.yml'
        workflow.parent.mkdir(parents=True, exist_ok=True)
        paths = ['formal/**', 'source.ts']
        workflow.write_text('on:\n  push:\n    paths: ' + json.dumps(paths + (['scripts/**'] if push_scripts else []))
                            + '\n  pull_request:\n    paths: ' + json.dumps(paths + (['scripts/**'] if pr_scripts else [])) + '\n')

    def save(self):
        (self.model / 'results').mkdir(exist_ok=True)
        (self.model / 'results/run.json').write_text(json.dumps(self.receipt))

    def test_stale_source_then_refreshed_receipt(self):
        self.assertEqual(verifier.verify(self.root), [])
        source = self.root / 'source.ts'
        source.write_text('changed')
        self.assertTrue(any('source.ts: stale hash' in e for e in verifier.verify(self.root)))
        self.receipt['hashes']['source.ts'] = hashlib.sha256(source.read_bytes()).hexdigest()
        self.save()
        self.assertEqual(verifier.verify(self.root), [])

    def test_wrong_named_property_and_failed_positive(self):
        for name, field, value in [('MutSafe', 'target', 'Other'), ('MutSafe', 'status', 'PASS'), ('Fixed', 'status', 'EXPECTED_FAIL'), ('Liveness', 'status', 'EXPECTED_FAIL')]:
            with self.subTest(name=name, field=field):
                original = self.receipt['checks'][name][field]
                self.receipt['checks'][name][field] = value
                self.save()
                self.assertTrue(verifier.verify(self.root))
                self.receipt['checks'][name][field] = original

    def test_every_recorded_hash_needs_both_workflow_triggers(self):
        script = self.root / 'scripts/lib/update-gate.sh'
        script.parent.mkdir(parents=True)
        script.write_text('fixture')
        # Even an extra recorded hash, beyond the minimum tracked inventory, needs coverage.
        self.receipt['hashes']['scripts/lib/update-gate.sh'] = hashlib.sha256(script.read_bytes()).hexdigest()
        self.save()
        for push, pr, missing in [(False, True, 'push'), (True, False, 'pull_request')]:
            with self.subTest(missing=missing):
                self.write_workflow(push, pr)
                self.assertTrue(any('scripts/lib/update-gate.sh' in e and missing + '.paths' in e
                                    for e in verifier.verify(self.root)))
        self.write_workflow(True, True)
        self.assertEqual(verifier.verify(self.root), [])
        # The workflow remains the authority: removing its coverage must fail again.
        self.write_workflow()
        self.assertTrue(verifier.verify(self.root))



    def test_workflow_block_lists_and_fail_closed_syntax(self):
        workflow = self.root / '.github/workflows/formal.yml'
        workflow.write_text('on:\n  push:\n    paths:\n      - "formal/**"\n      - "source.ts"\n'
                            '  pull_request:\n    paths:\n      - "formal/**"\n      - "source.ts"\n')
        self.assertEqual(verifier.verify(self.root), [])
        for invalid in (workflow.read_text().replace('formal/**', 'formal/*'), 'on: {}\n'):
            with self.subTest(invalid=invalid):
                workflow.write_text(invalid)
                self.assertTrue(any('cannot verify trigger coverage' in e for e in verifier.verify(self.root)))
        workflow.unlink()
        self.assertTrue(any('cannot verify trigger coverage' in e for e in verifier.verify(self.root)))


    def test_reject_invalid_receipts(self):
        for field, value in [('complete', False), ('tlcJarSHA256', 'wrong'), ('mutants', {}), ('checks', {})]:
            with self.subTest(field=field):
                original = self.receipt[field]
                self.receipt[field] = value
                self.save()
                self.assertTrue(verifier.verify(self.root))
                self.receipt[field] = original
        del self.receipt['hashes']['source.ts']
        self.save()
        self.assertTrue(any('source.ts: missing hash' in e for e in verifier.verify(self.root)))


if __name__ == '__main__':
    unittest.main()
