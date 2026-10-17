import importlib.util
import pathlib
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('operator_run', pathlib.Path(__file__).with_name('voicebar-hide1-visual-run.py'))
operator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(operator)


class OperatorTests(unittest.TestCase):
    def test_hide1_uses_shared_supervisor(self):
        output = pathlib.Path('/not-executed')
        with patch.object(operator.safety, 'NativeHost') as native, patch.object(operator.safety, 'supervise', return_value=7) as run:
            self.assertEqual(operator.main(output), 7)
            native.assert_called_once_with(output, 'hide1')
            run.assert_called_once_with(native.return_value)


if __name__ == '__main__': unittest.main()
