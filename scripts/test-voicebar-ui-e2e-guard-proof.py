import importlib.util
import hashlib
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
    def products_fixture(self, root, legacy=False):
        repo, output, sandbox = root / 'repo', root / 'output', root / 'sandbox'
        output.mkdir()
        for source in guard.SOURCES:
            path = repo / source
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('synthetic source: ' + source)
        binary = sandbox / 'VoiceBarQA.app/Contents/MacOS/VoiceBar'
        binary.parent.mkdir(parents=True)
        binary.write_bytes(b'synthetic voicebar_no_device_guard_version')
        (binary.parents[1] / 'Info.plist').write_bytes(plistlib.dumps({'UIE2EGate2245': True}))
        (output / 'sandbox-path.txt').write_text(str(sandbox))
        for name in ['device-guard.dylib', 'device-guard-probe', 'voicebar-ui-e2e-resident',
                     'voicebar-ui-e2e-permissions']:
            (output / name).write_bytes(('synthetic ' + name).encode())
        derived = output / 'DerivedData' if legacy else root / 'relocated.noindex/DerivedData'
        if not legacy:
            (output / 'derived-data-path.txt').write_text(str(derived) + '\n')
        runner = (derived / 'Build/Products/Debug/VoiceBarUIE2ETests-Runner.app/Contents'
                  '/MacOS/VoiceBarUIE2ETests-Runner')
        test = runner.parents[1] / 'PlugIns/VoiceBarUIE2ETests.xctest/Contents/MacOS/VoiceBarUIE2ETests'
        for path in [runner, test]:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(('synthetic ' + path.name).encode())
        return repo, output, derived, runner, test

    def write_synthetic_proof(self, repo, output):
        # Synthetic probe records exercise verification only; never claim blocked real APIs.
        proof = dict(version=1, paths=guard.PATHS, identities=guard.identities(repo, output), tests=[
            dict(path=p, passed=True, exit=86, events=['voicebar-no-device-guard-v1:installed',
                 'posix_spawn' if p == 'NSTask' else p]) for p in guard.PATHS])
        (output / 'device-guard-proof.json').write_text(json.dumps(proof))
        return proof

    def test_relocated_products_are_hashed_and_changed_bytes_refuse_authorization(self):
        for changed in ['test', 'runner']:
            with self.subTest(changed=changed), tempfile.TemporaryDirectory(suffix='.noindex') as tmp:
                repo, output, derived, runner, test = self.products_fixture(pathlib.Path(tmp))
                self.assertFalse((output / 'DerivedData').exists())
                self.assertEqual(guard.derived_data_path(output), derived.resolve())
                proof = self.write_synthetic_proof(repo, output)
                for product in [runner, test]:
                    self.assertEqual(proof['identities'][str(product.resolve())],
                                     hashlib.sha256(product.read_bytes()).hexdigest())
                self.assertEqual(guard.authorize(repo, output, 'hide1'), output / 'device-guard.dylib')
                (test if changed == 'test' else runner).write_bytes(b'changed product')
                with self.assertRaisesRegex(ValueError, 'stale or invalid'):
                    guard.authorize(repo, output, 'hide1')

    def test_recorded_path_change_refuses_even_with_identical_product_bytes(self):
        import shutil
        with tempfile.TemporaryDirectory(suffix='.noindex') as tmp:
            root = pathlib.Path(tmp)
            repo, output, derived, _, _ = self.products_fixture(root)
            self.write_synthetic_proof(repo, output)
            foreign = root / 'foreign.noindex/DerivedData'
            shutil.copytree(derived, foreign)
            (output / 'derived-data-path.txt').write_text(str(foreign))
            with self.assertRaisesRegex(ValueError, 'stale or invalid'):
                guard.authorize(repo, output, 'hide1')

    def test_legacy_fallback_only_without_metadata(self):
        with tempfile.TemporaryDirectory(suffix='.noindex') as tmp:
            repo, output, derived, _, _ = self.products_fixture(pathlib.Path(tmp), legacy=True)
            self.assertEqual(guard.derived_data_path(output), derived.resolve())
            self.write_synthetic_proof(repo, output)
            self.assertEqual(guard.verify(repo, output), output / 'device-guard.dylib')
            metadata = output / 'derived-data-path.txt'
            for invalid in ['', 'relative/DerivedData']:
                metadata.write_text(invalid)
                with self.assertRaisesRegex(ValueError, 'absolute recorded'):
                    guard.verify(repo, output)
            metadata.write_text(str(pathlib.Path(tmp) / 'missing.noindex/DerivedData'))
            with self.assertRaisesRegex(ValueError, 'exactly one UI test executable'):
                guard.verify(repo, output)

    def test_dangling_metadata_refuses_legacy_resolver_proof_and_consumers(self):
        with tempfile.TemporaryDirectory(suffix='.noindex') as tmp:
            root = pathlib.Path(tmp)
            repo, output, derived, _, _ = self.products_fixture(root, legacy=True)
            products = derived / 'Build/Products'
            products.mkdir(parents=True, exist_ok=True)
            (products / 'test.xctestrun').write_bytes(plistlib.dumps({'VoiceBarUIE2ETests': {}}))
            self.write_synthetic_proof(repo, output)
            self.assertEqual(guard.verify(repo, output), output / 'device-guard.dylib')

            metadata = output / 'derived-data-path.txt'
            metadata.symlink_to(root / 'missing-metadata-target.txt')
            with self.assertRaises(FileNotFoundError):
                guard.derived_data_path(output)
            with self.assertRaises(FileNotFoundError):
                guard.verify(repo, output)

            results_spec = importlib.util.spec_from_file_location(
                'uie2e_results', pathlib.Path(__file__).with_name('voicebar-ui-e2e-results.py'))
            results = importlib.util.module_from_spec(results_spec)
            results_spec.loader.exec_module(results)
            with self.assertRaises(FileNotFoundError):
                results.configure(output, output / 'QA.app', output / 'sandbox')
            self.assertFalse((output / 'UIE2E.xctestrun').exists())

            supervisor_spec = importlib.util.spec_from_file_location(
                'uie2e_supervisor', pathlib.Path(__file__).with_name('voicebar-ui-e2e-supervisor.py'))
            supervisor = importlib.util.module_from_spec(supervisor_spec)
            supervisor_spec.loader.exec_module(supervisor)
            with self.assertRaises(FileNotFoundError):
                supervisor.NativeHost(output, 'full')

    def test_duplicate_relocated_test_executables_refuse_proof(self):
        with tempfile.TemporaryDirectory(suffix='.noindex') as tmp:
            repo, output, derived, _, test = self.products_fixture(pathlib.Path(tmp))
            duplicate = derived / 'Build/Products/Other/VoiceBarUIE2ETests.xctest/Contents/MacOS/VoiceBarUIE2ETests'
            duplicate.parent.mkdir(parents=True)
            duplicate.write_bytes(test.read_bytes())
            with self.assertRaisesRegex(ValueError, 'exactly one UI test executable'):
                guard.identities(repo, output)

    def test_missing_proof_refuses(self):
        with tempfile.TemporaryDirectory(suffix='.noindex') as root:
            with self.assertRaises(FileNotFoundError):
                guard.verify(pathlib.Path(root), pathlib.Path(root))

    def test_exact_proof_required_and_every_tripwire_must_pass(self):
        with tempfile.TemporaryDirectory(suffix='.noindex') as root:
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
        with tempfile.TemporaryDirectory(suffix='.noindex') as root:
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
        with tempfile.TemporaryDirectory(suffix='.noindex') as root:
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
