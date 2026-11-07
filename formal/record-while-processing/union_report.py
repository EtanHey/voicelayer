"""Require and report the union of all G/I exact-property checks, with no omitted model."""
import json
import sys
from pathlib import Path
root = Path(__file__).resolve().parents[2]
models = ["record-while-processing", "record-while-processing-runtime", "ptt-silence-timeout"]
lines = ["| Model | Property | Mutant | Result |", "| --- | --- | --- | --- |"]
total = 0
for model in models:
    manifest = json.loads((root / "formal" / model / "checks.json").read_text())
    run = json.loads((root / ".build.noindex" / model / "run.json").read_text())
    assert run["complete"] and set(run["checks"]) == set(manifest["checks"]), model
    for name, check in manifest["checks"].items():
        result = run["checks"][name]
        assert result["status"] == ("PASS" if check["role"] == "positive" else "EXPECTED_FAIL"), (model, name)
        if check["role"] != "mutant": continue
        assert result["target"] == check["target"]
        total += 1
        lines.append(f"| {model} | {check['target']} | {name} | exact-property FAIL |")
summary = f"UNION: {total}/{total} mutants killed; all ownership/readability/retention properties retained. D3 retires only CapAlwaysFires, CaptureWithinCap and CapStops; renewable 10-minute silence replaces capped recording."
print(summary)
print("\n".join(lines))
if "--record" in sys.argv:
    destination = root / "formal/record-while-processing/results/UNION-MUTANTS.md"
    destination.write_text(summary + "\n\n" + "\n".join(lines) + "\n")
