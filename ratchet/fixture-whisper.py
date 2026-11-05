"""Deterministic decoder fixture for historical stdout and current segment adapters."""
import json
from pathlib import Path
import sys

text = "Recovered synthetic answer."
args = sys.argv[1:]
if "-oj" in args:
    prefix = args[args.index("-of") + 1]
    Path(prefix + ".json").write_text(json.dumps({
        "transcription": [{"text": text, "offsets": {"from": 0, "to": 1000}}],
    }))
print(text)
