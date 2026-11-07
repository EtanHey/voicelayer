#!/usr/bin/env python3
"""Run Lane K's focused counterexamples; always restore the exact source bytes."""
import os
from pathlib import Path
import shutil
import subprocess

root = Path(__file__).resolve().parent.parent
output = root / "docs.local/lane-k"
output.mkdir(parents=True, exist_ok=True)
bun = os.environ.get("BUN") or shutil.which("bun") or "/opt/homebrew/bin/bun"
mutants = [
    ("energy-tail", "src/parakeet-backend.ts",
     "lastSpeechSeconds !== undefined && lastSpeechSeconds - result.last_token_end_s",
     "info.lastActiveSeconds - result.last_token_end_s", "ZERO Whisper calls"),
    ("timestamps-disabled", "src/stt.ts",
     '...(!gateEnabled ? ["--no-timestamps"] : []),',
     '"--no-timestamps",', "CLI fallback removes an invented Thank you"),
    ("fresh-speech-veto-removed", "src/stt.ts",
     "if (gated.removed.length && !isCjkHallucinationCandidate(text, explicitLanguage)) {",
     "if (false && !isCjkHallucinationCandidate(text, explicitLanguage)) {",
     "quiet closer after loud speech"),
]
for name, filename, needle, replacement, case in mutants:
    path = root / filename
    original = path.read_bytes()
    source = original.decode()
    if source.count(needle) != 1:
        raise SystemExit(f"{name}: mutation target drifted")
    try:
        path.write_text(source.replace(needle, replacement))
        result = subprocess.run(
            ["nice", "-n", "19", bun, "test", "src/__tests__/parakeet-tail.test.ts", "-t", case],
            cwd=root, env=os.environ.copy(), capture_output=True, text=True, timeout=60,
        )
        transcript = result.stdout + result.stderr
        (output / f"{name}.log").write_text(transcript)
        if result.returncode != 1 or "(fail) Lane K:" not in transcript:
            raise SystemExit(f"{name}: mutant survived or test did not reach its assertion; see {output}")
        print(f"{name}: expected FAIL (killed)", flush=True)
    finally:
        path.write_bytes(original)
