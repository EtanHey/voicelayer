"""Hold create-before-write open; a readiness filename must imply full contents."""
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import patch
import hook_fixture_registry as registry


class PublicationTest(unittest.TestCase):
    def test_diagnostic_output_replaces_non_utf8_bytes(self):
        output = registry.diagnostic_output([sys.executable, "-c",
            "import os; os.write(1, b'before\\x88after'); os.write(2, b'\\xff')"])
        self.assertEqual(output, "before\ufffdafter")

    def test_readiness_is_invisible_until_complete(self):
        for value in ("12345", "12345 67890"):
            with self.subTest(value=value), tempfile.TemporaryDirectory() as directory:
                target = Path(directory) / "fixture.pid"
                opened, release = threading.Event(), threading.Event()
                write_text = Path.write_text
                errors = []

                def paused_write(path, contents):
                    write_text(path, "")
                    opened.set()
                    if not release.wait(5):
                        raise TimeoutError("publication barrier not released")
                    return write_text(path, contents)

                def produce():
                    try:
                        registry.publish(target, value)
                    except BaseException as error:
                        errors.append(error)

                with patch.object(Path, "write_text", paused_write):
                    producer = threading.Thread(target=produce)
                    producer.start()
                    try:
                        self.assertTrue(opened.wait(5), "producer never opened its receipt")
                        self.assertFalse(target.exists(), "empty PID receipt exposed as ready")
                    finally:
                        release.set()
                        producer.join(5)
                self.assertFalse(producer.is_alive())
                self.assertEqual(errors, [])
                self.assertEqual(target.read_text(), value)


if __name__ == "__main__":
    unittest.main()
