import importlib.util
import json
import pathlib
import plistlib
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('guard', pathlib.Path(__file__).with_name('voicebar-ui-e2e-guard-proof.py'))
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


class GuardProofTests(unittest.TestCase):
    def test_missing_proof_refuses(self):
        with tempfile.TemporaryDirectory() as root:
            with self.assertRaises(FileNotFoundError):
                guard.verify(pathlib.Path(root), pathlib.Path(root))

    def test_exact_proof_required_and_every_tripwire_must_pass(self):
        with tempfile.TemporaryDirectory() as root:
            output = pathlib.Path(root)
            proof = dict(version=1, paths=guard.PATHS, identities={'build': 'exact'}, tests=[
                dict(path=p, passed=True, exit=86, events=['voicebar-no-device-guard-v1:installed',
                     'posix_spawn' if p == 'NSTask' else p]) for p in guard.PATHS])
            def write():
                (output / 'device-guard-proof.json').write_text(json.dumps(proof))
            write()
            with patch.object(guard, 'identities', return_value={'build': 'exact'}):
                self.assertEqual(guard.verify(output, output), output / 'device-guard.dylib')
                for test in proof['tests']:
                    test['passed'] = False
                    write()
                    with self.assertRaises(ValueError):
                        guard.verify(output, output)
                    test['passed'] = True
                write()
            with patch.object(guard, 'identities', return_value={'build': 'changed'}):
                with self.assertRaises(ValueError):
                    guard.verify(output, output)

    def test_every_scenario_that_compiles_gate2245_requires_the_guard(self):
        self.assertEqual(guard.GUARDED_SCENARIOS, {'hide1', 'gate2246'})
        for scenario in ['hide1', 'gate2246']:
            self.assertTrue(guard.required(scenario))
        for scenario in ['full', 'focused-338']:
            self.assertFalse(guard.required(scenario))

    def test_a_gate2245_build_requires_the_guard_whatever_the_scenario(self):
        with tempfile.TemporaryDirectory() as root:
            plist = pathlib.Path(root) / 'Info.plist'
            plist.write_bytes(plistlib.dumps({'UIE2EGate2245': True}))
            self.assertTrue(guard.required('full', plist))
            plist.write_bytes(plistlib.dumps({'UIE2EGate2245': False}))
            self.assertFalse(guard.required('full', plist))
            self.assertTrue(guard.required('hide1', plist))
            plist.write_bytes(b'not a plist')
            with self.assertRaises(Exception):
                guard.required('full', plist)

    def test_authorize_verifies_hide1_and_claims_the_retry_only_for_gate2246(self):
        with tempfile.TemporaryDirectory() as root:
            output = pathlib.Path(root)
            with self.assertRaises(FileNotFoundError):
                guard.authorize(output, output, 'hide1')
            self.assertFalse((output / 'native-retry-claimed.json').exists())
            with patch.object(guard, 'verify', return_value=output / 'device-guard.dylib') as verify:
                self.assertEqual(guard.authorize(output, output, 'hide1'), output / 'device-guard.dylib')
                self.assertFalse((output / 'native-retry-claimed.json').exists())
                guard.authorize(output, output, 'gate2246')
                self.assertTrue((output / 'native-retry-claimed.json').exists())
                with self.assertRaises(FileExistsError):
                    guard.authorize(output, output, 'gate2246')
                self.assertIsNone(guard.authorize(output, output, 'full'))
                self.assertEqual(verify.call_count, 3)


if __name__ == '__main__':
    unittest.main()
