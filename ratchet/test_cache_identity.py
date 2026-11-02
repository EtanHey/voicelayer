import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class IdentityTests(unittest.TestCase):
    def test_identical_checkout_content_ignores_python_bytecode_and_mtime(self):
        script = Path(__file__).with_name('cache_identity.sh').resolve()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(['git', 'init', '-q', directory], check=True)
            (root/'ratchet').mkdir()
            source = root/'ratchet'/'run.py'
            source.write_text('print(1)\n')
            subprocess.run(['git', '-C', directory, 'add', 'ratchet'], check=True)
            subprocess.run(['git', '-C', directory, '-c', 'user.name=Test', '-c', 'user.email=test@example.com', 'commit', '-qm', 'fixture'], check=True)
            def identity():
                return subprocess.check_output(['bash', str(script), 'HEAD'], cwd=root)
            first = identity()
            (root/'ratchet'/'__pycache__').mkdir()
            (root/'ratchet'/'__pycache__'/'run.pyc').write_bytes(b'changed timestamps')
            os.utime(source, (1, 1))
            self.assertEqual(first, identity())
