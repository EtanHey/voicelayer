import importlib.util
import json
from pathlib import Path
import unittest

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("inventory", HERE / "c5-inventory.py")
inventory = importlib.util.module_from_spec(spec)
spec.loader.exec_module(inventory)


class C5InventoryTests(unittest.TestCase):
    def test_regenerated_source_ledger_matches_committed_receipt(self):
        self.assertEqual(inventory.generate(), json.loads((HERE / "c5-inventory.json").read_text()))

    def test_all_historical_cells_and_unknowns_survive(self):
        cells = inventory.generate()["cells"]
        self.assertEqual(len(cells), 3300)
        self.assertEqual(len({c["id"] for c in cells}), 3300)
        self.assertEqual(sum(c["historical"] in ("X", "D") for c in cells), 77)
        self.assertEqual(sum(c["historical"] == "?" and c["c5"] == "UNKNOWN" for c in cells), 182)
        self.assertEqual(sum(c["c5"] == "UNKNOWN_NEWLY_REACHABLE" for c in cells), 165)
        self.assertEqual(sum(c["c5"] == "UNKNOWN_REFINEMENT" for c in cells), 19)
        self.assertEqual(sum(c["c5"] == "SURVIVING" for c in cells), 34)
        self.assertEqual(inventory.generate()["native"], "NOT_RUN")

    def test_surviving_only_from_a_source_check(self):
        result = inventory.generate()
        for cell in result["cells"]:
            if cell["c5"] == "SURVIVING":
                self.assertIn("defectAnchor", cell.get("sourceLayers", {}), cell["id"])
        for overlay in result["overlays"]:
            if overlay["c5"] in ("SURVIVING", "REMOVED"):
                self.assertIn("defectAnchor", overlay, overlay["id"])


if __name__ == "__main__":
    unittest.main()
