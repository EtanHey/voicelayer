"""Unit safety checks; no fixture here counts as a real ratchet row."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("runner", Path(__file__).with_name("run.py"))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class RunnerTests(unittest.TestCase):
    def test_wrapper_refuses_every_effective_path_before_spawn(self):
        with tempfile.TemporaryDirectory() as directory:
            run = runner.Run.__new__(runner.Run)
            run.root = Path(directory)
            run.files, run.procs, run.source = [], [], run.root
            names = ("VOICELAYER_SOCKET_PATH", "VOICELAYER_MCP_SOCKET_PATH", "VOICELAYER_STATE_DIR",
                     "VOICELAYER_TMP_ROOT", "QA_VOICE_SOCKET_PATH", "QA_VOICE_MCP_SOCKET_PATH", "RATCHET_RESIDENT")
            safe = {key: str(run.root / str(i)) for i, key in enumerate(names)}
            for key in names:
                env = dict(safe, **{key: "/tmp/voicelayer.sock"})
                with self.subTest(key=key), patch.object(runner.Path, "open"), patch.object(runner.subprocess, "Popen") as spawn:
                    with self.assertRaises(RuntimeError):
                        run.launch(["never-run"], env)
                    spawn.assert_not_called()

    def test_missing_binary_emits_fail_rows_and_nonzero_exit(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            argv = ["run.py", "--output", directory]
            with patch.object(runner, "Run", side_effect=FileNotFoundError("missing real binary")), \
                    patch.object(runner, "sha", return_value="a" * 40), patch("sys.argv", argv), \
                    patch("builtins.print"):
                self.assertEqual(runner.main(), 1)
            rows = json.loads((output / "result.json").read_text())
            self.assertEqual(len(rows), 3)
            self.assertTrue(all(row["status"] == "FAIL" and row["error"] for row in rows))


if __name__ == "__main__":
    unittest.main()
