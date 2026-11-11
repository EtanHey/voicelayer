import importlib.util
import json
import os
from pathlib import Path
import shutil
import unittest

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("model_table", HERE / "model-table.py")
model_table = importlib.util.module_from_spec(spec)
spec.loader.exec_module(model_table)
JAVA = shutil.which("java", path="/opt/homebrew/opt/openjdk/bin:" + os.environ.get("PATH", ""))


class ModelTableTests(unittest.TestCase):
    @unittest.skipUnless(JAVA, "SKIP LOUDLY: no Java runtime, so TLC cannot regenerate the model table")
    def test_tlc_table_matches_committed_hash(self):
        _, manifest = model_table.generate()
        self.assertEqual(manifest, json.loads((HERE / "model-table.json").read_text()))

    def test_parser_reads_tlc_values(self):
        self.assertEqual(model_table.parse_values('<< [ a |-> TRUE, b |-> "x" ], <<1, FALSE>> >>'),
                         [({"a": True, "b": "x"}, (1, False))])


if __name__ == "__main__":
    unittest.main()
