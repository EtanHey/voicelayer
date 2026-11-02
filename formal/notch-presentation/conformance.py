"""Collapse TLC states only on dimensions unobserved by the real Swift projection.

Replays the Fixed policy: after Lane A realised it, the application must match Fixed, not the
historical Current bugs (README: "update the replay to the new implementation")."""
import json
from pathlib import Path
import re

root = Path(__file__).resolve().parents[2]
labels = json.loads((root / ".build.noindex/notch-presentation/fixed-states.json").read_text())


def record(text):
    return {key: (value == "TRUE" if value in {"TRUE", "FALSE"} else value.strip('"'))
            for key, value in re.findall(r'(\w+) \|-> ("[^"]*"|TRUE|FALSE)', text)}


cases = {}
for label in labels:
    shown, state = label.split("/\\ s = ")
    row = {"input": record(state), "expected": record(shown)}
    row["input"].pop("updateBusy")  # Only affects note lifecycle, not rendering.
    cases[json.dumps(row, sort_keys=True)] = row
path = root / ".build.noindex/notch-presentation/conformance.json"
path.write_text(json.dumps(list(cases.values())))
print(f"Notch (Fixed): {len(labels)} TLC states -> {len(cases)} distinct real-resolver cases; {path}")
