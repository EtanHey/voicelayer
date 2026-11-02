"""Fail-closed per-property mutation checks, including the temporal counterexample."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
directory = Path(__file__).resolve().parent
manifest = json.loads((directory / "checks.json").read_text())
assert {p.stem for p in directory.glob("*.cfg")} == set(manifest["checks"])
results = directory / "results"
results.mkdir(exist_ok=True)
cache = root / ".build.noindex/ptt-silence-timeout"
cache.mkdir(parents=True, exist_ok=True)
jar = Path.home() / ".cache/tla/tla2tools.jar"
def digest(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()
paths = [directory / "PttSilenceTimeout.tla", directory / "checks.json", directory / "check.sh", Path(__file__), jar] + list(directory.glob("*.cfg")) + [root / s for s in manifest["sources"]]
hashes = {str(p.relative_to(root)) if p.is_relative_to(root) else str(p): digest(p) for p in paths}
mutants = {}
with tempfile.TemporaryDirectory(dir=cache) as temp:
    for name, expected in manifest["checks"].items():
        result = subprocess.run(["nice", "-n", "19", "java", "-Xmx512m", "-XX:+UseParallelGC", "-cp", str(jar),
            "tlc2.TLC", "-workers", "1", "-seed", "1", "-fp", "0", "-metadir", str(Path(temp) / name),
            "-config", name + ".cfg", "PttSilenceTimeout.tla"], cwd=directory, env=os.environ,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=180)
        (results / (name + ".log")).write_text(result.stdout)
        if expected in {"SettlesAfterSilence", "CapStops"}:
            assert result.returncode == 13 and "Temporal properties were violated" in result.stdout, result.stdout
            # This config declares exactly one temporal property, so the violation is unambiguous.
            assert (directory / (name + ".cfg")).read_text().count("PROPERT") == 1 and expected in (directory / (name + ".cfg")).read_text()
        elif expected:
            assert result.returncode == 12, result.stdout
            assert re.findall(r"Invariant (\w+) is violated", result.stdout) == [expected], result.stdout
        else:
            assert result.returncode == 0 and "Model checking completed. No error has been found." in result.stdout, result.stdout
        mutants[name] = dict(property=expected, exit=result.returncode)
        print(f"{name}: {expected or 'PASS'} exit={result.returncode}", flush=True)
assert [digest(p) for p in paths] == list(hashes.values()), "Evidence changed during checking"
(results / "run.json").write_text(json.dumps(dict(hashes=hashes, checks=mutants), indent=2) + "\n")
