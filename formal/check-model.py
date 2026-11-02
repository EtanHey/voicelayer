"""Bounded, fail-closed TLC runner shared by the 2.2.61 models."""
import json
import hashlib
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

directory = Path(sys.argv[1]).resolve()
manifest = json.loads((directory / "checks.json").read_text())
assert {file.stem for file in directory.glob("*.cfg")} == set(manifest["checks"]), "Every config needs an expected result"
root = directory.parents[1]
logs = directory / "results"
logs.mkdir(exist_ok=True)
cache = root / ".build.noindex" / directory.name
cache.mkdir(parents=True, exist_ok=True)
jar = Path.home() / ".cache/tla/tla2tools.jar"
assert jar.is_file(), f"Missing TLC: {jar}"
def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

receipt = dict(sourceBaseline=manifest["sourceBaseline"],
               runnerSHA256=digest(Path(__file__)),
               sourceHashes={path: digest(root / path) for path in manifest["sources"]},
               specSHA256=digest(directory / f'{manifest["module"]}.tla'),
               cfgSHA256={name: digest(directory / f"{name}.cfg") for name in manifest["checks"]},
               tlcJarSHA256=digest(jar))
with tempfile.TemporaryDirectory(prefix="tlc-", dir=cache) as temporary:
    run = Path(temporary)
    for name, expected in manifest["checks"].items():
        command = ["nice", "-n", "19", "java", "-Xmx512m", "-XX:+UseParallelGC",
                   "-cp", str(jar), "tlc2.TLC", "-workers", "1",
                   "-seed", "1", "-fp", "0", "-metadir", str(run / name),
                   "-config", f"{name}.cfg"]
        if name in {"Current", "Fixed"}:
            command += ["-dump", "dot,actionlabels", str(run / f"{name}.dot")]
        command += [f'{manifest["module"]}.tla']
        result = subprocess.run(command, cwd=directory, env=os.environ,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, timeout=180)
        output = result.stdout
        (logs / f"{name}.log").write_text(output)
        if expected and expected.startswith("temporal:"):
            prop = expected.removeprefix("temporal:")
            config = (directory / f"{name}.cfg").read_text()
            assert re.findall(r"PROPERT(?:Y|IES)\s+(\w+)", config) == [prop], config
            assert result.returncode == 13 and "Temporal properties were violated" in output, output
        elif expected:
            assert result.returncode == 12, output
            assert re.findall(r"Invariant (\w+) is violated", output) == [expected], output
        else:
            assert result.returncode == 0, output
            assert "Model checking completed. No error has been found." in output, output
        counts = re.search(r"\d+ states generated, \d+ distinct states found", output)
        assert counts or (expected and "violated by the initial state" in output), output
        print(f"{directory.name}/{name}: {expected or 'PASS'}; {counts[0] if counts else 'initial-state violation'}", flush=True)
        if name in {"Current", "Fixed"}:
            # TLC's graph is used as the conformance corpus, not hand-picked examples.
            nodes, edges = {}, []
            for line in (run / f"{name}.dot").read_text().splitlines():
                match = re.match(r'(-?\d+) \[label="((?:\\.|[^"\\])*)"', line)
                if match:
                    nodes[match[1]] = json.loads('"' + match[2] + '"')
                edge = re.match(r'(-?\d+) -> (-?\d+) ', line)
                if edge:
                    edges.append(edge.groups())
            labels = list(nodes.values())
            distinct = int(re.findall(r"(\d+) distinct states found", output)[-1])
            assert len(labels) == distinct, "Incomplete TLC conformance graph"
            corpus = cache / f"{name.lower()}-states.json"
            corpus.write_text(json.dumps(labels))
            (cache / f"{name.lower()}-graph.json").write_text(json.dumps(dict(nodes=nodes, edges=edges)))
            print(f"Conformance corpus: {corpus} ({distinct} states)", flush=True)
assert digest(Path(__file__)) == receipt["runnerSHA256"], "Runner changed during check"
assert digest(directory / f'{manifest["module"]}.tla') == receipt["specSHA256"], "Spec changed during check"
assert all(digest(directory / f"{name}.cfg") == sha for name, sha in receipt["cfgSHA256"].items()), "Config changed during check"
assert all(digest(root / path) == sha for path, sha in receipt["sourceHashes"].items()), "Source changed during check"
(logs / "run.json").write_text(json.dumps(receipt, indent=2) + "\n")
