import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest

from speech_data_conformance import speech_cases


class SpeechDataReplayTests(unittest.TestCase):
    def test_resume_edges_project_both_owners_and_physical_exit_orders(self):
        with tempfile.TemporaryDirectory() as directory:
            run = Path(directory)
            nodes, edges = [], []
            for queued in range(3):
                states = [("preparing", "none", "prepare_speech"), ("playing", "none", "start_playback"),
                          ("paused", "user", "user_pause"), ("paused", "f5", "f5_pause"),
                          ("playing", "none", "user_play"), ("playing", "none", "end_empty_auto_resume")]
                base = len(nodes)
                for phase, owner, event in states:
                    label = f's = [speech |-> "{phase}", queued |-> {queued}, owner |-> "{owner}", event |-> "{event}"]'
                    nodes.append(f'{len(nodes)} [label={json.dumps(label)}];\n')
                edges += [f'{base + 2} -> {base + 4} [label="UserPlay"];\n',
                          f'{base + 3} -> {base + 5} [label="End"];\n']
            for graph in ("F5PauseFixed", "F5PauseFixedTranscribing"):
                (run / f"{graph}.dot").write_text("".join(nodes + edges))
            rows = speech_cases(run)
            self.assertEqual(len(rows), 21)
            self.assertEqual(sum(row["phase"].startswith("resume_") for row in rows), 12)
            proof = json.loads((run / "speech-data-projection.json").read_text())
            self.assertEqual(set(proof["resume_edges"].values()), {6})
            self.assertEqual(len(proof["witnesses"]), 6)

    def test_sigkill_leaves_only_scratch_source_mutated(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "source"
            (root / "src").mkdir(parents=True)
            (root / "node_modules").mkdir()
            source = root / "src/tts.ts"
            source.write_text("fixed tracked bytes\n")
            script = """from speech_data_conformance import mutant_copy
from pathlib import Path
import os, signal, sys
with mutant_copy(Path(sys.argv[1]), Path(sys.argv[2])) as scratch:
    (scratch / 'src/tts.ts').write_text('mutant bytes\\n')
    print(scratch, flush=True)
    os.kill(os.getpid(), signal.SIGKILL)
"""
            child = subprocess.run([sys.executable, "-c", script, str(root), directory],
                                   cwd=Path(__file__).parent, env=os.environ, stdout=subprocess.PIPE, text=True)
            self.assertEqual(child.returncode, -signal.SIGKILL)
            self.assertEqual(source.read_text(), "fixed tracked bytes\n")
            self.assertEqual((Path(child.stdout.strip()) / "src/tts.ts").read_text(), "mutant bytes\n")


if __name__ == "__main__":
    unittest.main()
