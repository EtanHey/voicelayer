import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('gate', Path(__file__).with_name('e2e-2.4.py'))
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
BUILD_ROOT = Path(__file__).resolve().parents[1] / '.build.noindex'
BUILD_ROOT.mkdir(exist_ok=True)

class AttestTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=BUILD_ROOT, suffix='.noindex')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.evidence = self.root / 'run.log'
        self.evidence.write_text('controlled test evidence, no real run claimed')
        self.head = 'a' * 40
        self.digest = 'b' * 64
        self.data = dict(schema='voicelayer.e2e24-attestation.v1', row='mute audio exclusion',
            head=self.head, candidateBundleSha256=self.digest, host='m1-test-fixture',
            timestamp='2026-11-08T12:00:00Z', producer='scripts/e2e-2.4.py',
            evidence=[dict(path='run.log', sha256=gate.file_sha256(self.evidence))], result='PASS')
        self.path = self.root / 'receipt.json'

    def validate(self):
        self.path.write_text(json.dumps(self.data))
        return gate.validate_attestation(self.data['row'], self.path, self.head, self.digest,
                                         '2026-11-08T11:00:00Z', now=1794139200)

    def test_valid_schema_without_real_producer_stays_unproved(self):
        result = self.validate()
        self.assertEqual(result['status'], 'UNPROVED-native')
        self.assertIn('producer', result['reason'])
        self.assertEqual(result['receiptSha256'], gate.file_sha256(self.path))

    def test_all_five_rows_require_registered_real_producers(self):
        self.assertEqual(len(gate.ATTEST_ROWS),5)
        for row in gate.ATTEST_ROWS:
            self.data['row'] = row
            self.assertEqual(self.validate()['status'],'UNPROVED-native')

    def test_rejects_bare_file_and_wrong_schema(self):
        self.path.write_text('PASS')
        with self.assertRaises(ValueError):
            gate.validate_attestation(self.data['row'], self.path, self.head, self.digest, '2026-11-08T11:00:00Z', now=1794139200)
        self.data['schema'] = 'unknown'
        with self.assertRaises(ValueError): self.validate()

    def test_rejects_wrong_sha_bundle_row_result_and_host(self):
        for key, value in [('head','c'*40), ('candidateBundleSha256','d'*64),
                           ('result','FAIL'), ('host','')]:
            with self.subTest(key=key):
                original = self.data[key]; self.data[key] = value
                with self.assertRaises(ValueError): self.validate()
                self.data[key] = original
        self.path.write_text(json.dumps(self.data))
        with self.assertRaises(ValueError):
            gate.validate_attestation('installed update and restore', self.path, self.head, self.digest, '2026-11-08T11:00:00Z', now=1794139200)
        with self.assertRaises(ValueError):
            gate.validate_attestation('unknown', self.path, self.head, self.digest, '2026-11-08T11:00:00Z')

    def test_rejects_stale_future_prebuild_and_invalid_times(self):
        for value in ['2026-11-06T12:00:00Z','2026-11-09T12:00:00Z',
                      '2026-11-08T10:00:00Z','yesterday']:
            with self.subTest(value=value):
                self.data['timestamp'] = value
                with self.assertRaises(ValueError): self.validate()

    def test_rejects_missing_tampered_escaping_duplicate_evidence(self):
        original = self.data['evidence'][0].copy()
        for entries in [[], [dict(path='missing',sha256='0'*64)],
                        [dict(path='../escape',sha256='0'*64)],
                        [dict(path='run.log',sha256='0'*64)], [original, original]]:
            self.data['evidence'] = entries
            with self.assertRaises(ValueError): self.validate()

    def test_t3_uses_existing_validator_and_does_not_prove_all_f5_gestures(self):
        self.data = dict(schema='voicelayer.t3-optf5-proof.v2', gitCommit=self.head,
                         timestamp='2026-11-08T12:00:00Z')
        self.path.write_text(json.dumps(self.data))
        with patch.object(gate, 'run_bounded', return_value=__import__('subprocess').CompletedProcess([],0,'','')) as run:
            result = gate.validate_attestation('F5 physical gestures', self.path, self.head, self.digest,
                '2026-11-08T11:00:00Z', candidate_app=self.root/'Candidate.app', now=1794139200)
        self.assertIn('t3-optf5-proof.ts', ' '.join(map(str,run.call_args.args[0])))
        self.assertEqual(result['status'],'UNPROVED-native')
        self.assertIn('Option+F5', result['reason'])

    def test_cli_requires_candidate_and_rejects_duplicate_row_before_tests(self):
        with self.assertRaises(ValueError): gate.load_attestations(['mute audio exclusion=x'],None)
        import plistlib
        app = self.root/'Candidate.app'
        (app/'Contents').mkdir(parents=True)
        (app/'Contents/Info.plist').write_bytes(plistlib.dumps(dict(GitCommit=self.head,BuildTimeUTC='2026-11-08T11:00:00Z')))
        self.path.write_text(json.dumps(self.data))
        with patch.object(gate.subprocess,'check_output',return_value=self.head), \
             patch.object(gate,'run_bounded',return_value=__import__('subprocess').CompletedProcess([],0,self.digest+'\n','')), \
             patch.object(gate.time,'time',return_value=1794139200):
            result = gate.load_attestations(['mute audio exclusion='+str(self.path)],app)
            self.assertEqual(result['mute audio exclusion']['status'],'UNPROVED-native')
            for values in [['mute audio exclusion='+str(self.path)]*2, ['unknown='+str(self.path)], ['bare-file']]:
                with self.assertRaises(ValueError): gate.load_attestations(values,app)
        with patch.object(gate.subprocess,'check_output',return_value='c'*40):
            with self.assertRaises(ValueError): gate.load_attestations(['mute audio exclusion='+str(self.path)],app)

    def test_attestation_cannot_override_a_native_surface(self):
        rows = gate.native_rows(set(), {'dictionary CRUD':dict(status='PASS')})
        self.assertNotEqual(next(row for row in rows if row['flow']=='dictionary CRUD')['status'],'PASS')

    def test_t3_validator_failure_is_not_accepted(self):
        self.data = dict(schema='voicelayer.t3-optf5-proof.v2',gitCommit=self.head,timestamp='2026-11-08T12:00:00Z')
        self.path.write_text(json.dumps(self.data))
        with patch.object(gate,'run_bounded',return_value=__import__('subprocess').CompletedProcess([],1,'','bad proof')):
            with self.assertRaises(ValueError):
                gate.validate_attestation('F5 physical gestures',self.path,self.head,self.digest,
                    '2026-11-08T11:00:00Z',candidate_app=self.root/'Candidate.app',now=1794139200)

if __name__ == '__main__': unittest.main()
