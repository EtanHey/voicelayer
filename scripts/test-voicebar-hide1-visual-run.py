import importlib.util
import importlib.machinery
import contextlib
import io
import os
import pathlib
import runpy
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('operator_run', pathlib.Path(__file__).with_name('voicebar-hide1-visual-run.py'))
operator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(operator)


class OperatorTests(unittest.TestCase):
    def test_hide1_uses_shared_supervisor(self):
        output = pathlib.Path('/not-executed')
        with patch.object(operator.safety, 'main', return_value=7) as run:
            self.assertEqual(operator.main(output), 7)
            run.assert_called_once_with([str(output), '--scenario', 'hide1'])

    def test_hide1_helper_and_cli_refuse_before_native_access_when_locked(self):
        for entry in ['helper', 'cli']:
            with self.subTest(entry=entry), tempfile.TemporaryDirectory() as tmp:
                lock = pathlib.Path(tmp) / ('voicebar-ui-e2e-supervisor-%d.lock' % os.getuid())
                original_load = importlib.machinery.SourceFileLoader.exec_module
                def load(loader, module):
                    original_load(loader, module)
                    if module.__name__ == 'safety':
                        module.SUPERVISOR_LOCK_PATH = lock
                        module.NativeHost = native
                        module.supervise = run
                with patch.object(operator.safety, 'SUPERVISOR_LOCK_PATH', lock), \
                        patch.object(operator.safety, 'NativeHost') as native, \
                        patch.object(operator.safety, 'supervise', return_value=0) as run, \
                        patch.object(importlib.machinery.SourceFileLoader, 'exec_module', load), \
                        contextlib.redirect_stderr(io.StringIO()) as err:
                    with operator.safety.supervisor_lock():
                        if entry == 'helper':
                            self.assertEqual(operator.main(pathlib.Path(tmp)), 2)
                        else:
                            with patch.object(sys, 'argv', ['voicebar-hide1-visual-run.py', tmp]):
                                with self.assertRaises(SystemExit) as result:
                                    runpy.run_path(str(pathlib.Path(__file__).with_name('voicebar-hide1-visual-run.py')),
                                                   run_name='__main__')
                            self.assertEqual(result.exception.code, 2)
                    native.assert_not_called()
                    run.assert_not_called()
                self.assertIn('Another supervisor run is active', err.getvalue())


if __name__ == '__main__': unittest.main()
