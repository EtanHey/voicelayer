import importlib.util
import json
import pathlib
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


if __name__ == '__main__':
    unittest.main()
