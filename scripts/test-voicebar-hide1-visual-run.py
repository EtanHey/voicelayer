#!/usr/bin/env python3
"""Operator cleanup tests: no native processes, screen changes or audio."""
import importlib.util
import json
import pathlib
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location('operator_run', pathlib.Path(__file__).with_name('voicebar-hide1-visual-run.py'))
operator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(operator)


class OperatorTests(unittest.TestCase):
    def test_mute_restored_after_guard_failure_even_when_supervisor_cleanup_times_out(self):
        with tempfile.TemporaryDirectory() as temp:
            output = pathlib.Path(temp)
            (output / 'sandbox-path.txt').write_text('/tmp/not-executed-fixture')
            process = Mock()
            process.poll.return_value = None
            process.wait.side_effect = subprocess.TimeoutExpired('fixture', 40)
            with patch.object(operator, 'muted', side_effect=[False, False, False]), \
                 patch.object(operator, 'set_mute') as mute, \
                 patch.object(operator.subprocess, 'run'), \
                 patch.object(operator.subprocess, 'Popen', return_value=process):
                with self.assertRaises(subprocess.TimeoutExpired):
                    operator.main(output)
            self.assertEqual(mute.call_args_list[0].args, (True,))
            self.assertEqual(mute.call_args_list[-1].args, (False,))
            receipt = json.loads((output / 'operator-state.json').read_text())
            self.assertTrue(receipt['muteRestored'])
            self.assertIn('Mute guard changed', receipt['error'])
            self.assertIsNone(receipt['suiteExit'])


if __name__ == '__main__':
    unittest.main()
