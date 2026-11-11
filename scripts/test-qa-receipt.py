#!/usr/bin/env python3
"""Acceptance checks use synthetic files only; never audio or resident app state."""
import copy
import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('receipt', Path(__file__).with_name('qa-receipt.py'))
receipt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(receipt)


class ReceiptTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'output.log').write_text('PRIVATE-CONTENT-CANARY\n')
        self.data = dict(schema=1, run='synthetic-run', lane='L10', head='a'*40,
                         host='synthetic-host', status='PASS', pid=1, exit=0,
                         started='2026-11-10T00:00:00+00:00',
                         finished='2026-11-10T00:00:01+00:00', evidence=[dict(
                             path='output.log', visibility='private', sha256=hashlib.sha256(
                                 (self.root / 'output.log').read_bytes()).hexdigest())])

    def test_sealed_private_reference(self):
        self.assertEqual(receipt.validate(self.data, self.root), self.data)

    def test_missing_status_and_identity(self):
        for key in ('status', 'head', 'host', 'run', 'lane', 'pid'):
            with self.subTest(key=key), self.assertRaises(ValueError):
                data = copy.deepcopy(self.data)
                del data[key]
                receipt.validate(data, self.root)

    def test_dangling_or_changed_evidence(self):
        (self.root / 'output.log').write_text('changed')
        with self.assertRaises(ValueError):
            receipt.validate(self.data, self.root)
        (self.root / 'output.log').unlink()
        with self.assertRaises(ValueError):
            receipt.validate(self.data, self.root)

    def test_inline_private_canary_rejected(self):
        for key in ('output', 'transcript', 'command', 'environment'):
            with self.subTest(key=key), self.assertRaises(ValueError):
                receipt.validate(dict(self.data, **{key: 'PRIVATE-CONTENT-CANARY'}), self.root)

    def test_cannot_publish_private_reference(self):
        self.data['evidence'][0]['visibility'] = 'public'
        with self.assertRaises(ValueError):
            receipt.validate(self.data, self.root)

    def test_traversal_and_symlink(self):
        self.data['evidence'][0]['path'] = '../output.log'
        with self.assertRaises(ValueError):
            receipt.validate(self.data, self.root)
        self.data['evidence'][0]['path'] = 'alias.log'
        (self.root / 'alias.log').symlink_to(self.root / 'output.log')
        with self.assertRaises(ValueError):
            receipt.validate(self.data, self.root)

    def test_status_never_regrades_failure(self):
        self.data['exit'] = 1
        with self.assertRaises(ValueError):
            receipt.validate(self.data, self.root)
        self.data['status'] = 'FAIL'
        receipt.validate(self.data, self.root)
        for status in ('UNKNOWN', 'NOT_RUN', 'HOLD', 'RUNNING'):
            self.data.update(status=status, exit=None,
                             finished=None if status == 'RUNNING' else '2026-11-10T00:00:01+00:00')
            receipt.validate(self.data, self.root)


if __name__ == '__main__':
    unittest.main()
