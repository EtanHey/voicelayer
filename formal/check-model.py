"""Exact-property mutation gate. Default runs never rewrite tracked evidence."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
from graph_retention import graph_run
from tlc_support import tlc_jar

# Fresh-HOME M4 maxima * hosted slowdown 3.6 * margin 1.5, rounded up.
# RecordWhileProcessing: 43.645s -> 235.7s; RuntimeOwnership: 57.605s -> 311.1s.
TLC_CASE_SECONDS = {"record-while-processing": 240, "record-while-processing-runtime": 330}

parser = argparse.ArgumentParser()
parser.add_argument("directory", type=Path)
parser.add_argument("--record", action="store_true", help="Refresh normalized committed evidence")
parser.add_argument("--only", help="Debug one config; never produces an acceptance receipt")
args = parser.parse_args()
directory = args.directory.resolve()
root = directory.parents[1]
cache = root / ".build.noindex" / directory.name
cache.mkdir(parents=True, exist_ok=True)
with graph_run(cache, prefix="tlc-", keep_runs=0) as run:
    manifest = json.loads((directory / "checks.json").read_text())
    assert {file.stem for file in directory.glob("*.cfg")} == set(manifest["checks"]), "Unregistered config"
    jar = tlc_jar()
    digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
    tracked = [directory / f'{manifest["module"]}.tla', directory / "checks.json", Path(__file__), Path(__file__).with_name("graph_retention.py"),
               *directory.glob("*.cfg"), *(root / file for file in manifest["sources"])]
    hashes = {str(path.relative_to(root)): digest(path) for path in tracked}
    declared = set()
    all_declared = set()
    for name, check in manifest["checks"].items():
        text = (directory / f"{name}.cfg").read_text()
        for line in re.findall(r"^(?:INVARIANTS|PROPERTIES) (.+)$", text, re.M):
            all_declared.update(line.split())
            if check["role"] == "positive": declared.update(line.split())
    assert declared == set(manifest["acceptance"]), "Positive properties and mutation manifest drifted"
    assert all_declared <= {row["target"] for row in manifest["checks"].values() if row["target"]}, "A declared property has no exact failing config"
    mutants = {target: [] for target in manifest["acceptance"]}
    for name, check in manifest["checks"].items():
        if check["role"] == "mutant": mutants[check["target"]].append(name)
    assert all(mutants.values()), "Every invariant/temporal property needs a mutant"
    checks = {name: check for name, check in manifest["checks"].items() if not args.only or name == args.only}
    assert checks and not (args.record and args.only)
    results = {}
    graph_hashes = {}
    (cache / "run.json").unlink(missing_ok=True)
    for name, check in checks.items():
        target, kind = check["target"], check["kind"]
        config = (directory / f"{name}.cfg").read_text()
        if target:
            declaration = "PROPERTIES" if kind == "temporal" else "INVARIANTS"
            assert re.findall(rf"^{declaration} (.+)$", config, re.M) == [target], "Mutants isolate one exact property"
        command = ["nice", "-n", "19", "java", "-Xmx512m", "-XX:+UseParallelGC", "-cp", str(jar), "tlc2.TLC",
                   "-noGenerateSpecTE", "-workers", "1", "-seed", "1", "-fp", "0", "-metadir", str(run / name),
                   "-config", f"{name}.cfg"]
        if name in {"Current", "Fixed"}: command += ["-dump", "dot,actionlabels", str(run / f"{name}.dot")]
        command += [f'{manifest["module"]}.tla']
        result = subprocess.run(command, cwd=directory, env=os.environ, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, text=True, timeout=TLC_CASE_SECONDS.get(directory.name, 180))
        output = result.stdout
        (cache / f"{name}.log").write_text(output)
        if kind == "invariant":
            valid = result.returncode == 12 and re.findall(r"Invariant (\w+) is violated", output) == [target]
        elif kind == "temporal":
            valid = result.returncode == 13 and re.findall(r"Temporal property (\w+) was violated", output) == [target]
        else:
            valid = result.returncode == 0 and "Model checking completed. No error has been found." in output
        assert valid, f"Unexpected result for {name}, expected {kind} {target}:\n{output}"
        counts = re.findall(r"([\d,]+) states generated, ([\d,]+) distinct states found", output)
        generated, distinct = map(lambda value: int(value.replace(",", "")), counts[-1]) if counts else (None, None)
        trace = []
        for block in re.split(r"\nState \d+:.*\n", output)[1:]:
            trace.append(re.split(r"\n(?:[\d,]+ states generated|The depth|Finished|Progress)", block)[0].strip())
        if not trace and "violated by the initial state:" in output:
            trace = [output.split("violated by the initial state:", 1)[1].split("Finished in", 1)[0].strip()]
        results[name] = dict(role=check["role"], kind=kind, target=target, status="PASS" if not target else "EXPECTED_FAIL",
                             generated=generated, distinct=distinct, trace=trace)
        print(f"{directory.name}/{name}: {results[name]['status']} {target or ''} ({distinct if distinct is not None else 'initial'} states)", flush=True)
        if name in {"Current", "Fixed"}:
            nodes, edges = {}, []
            for line in (run / f"{name}.dot").read_text().splitlines():
                node = re.match(r'(-?\d+) \[label="((?:\\.|[^"\\])*)"', line)
                edge = re.match(r'(-?\d+) -> (-?\d+) ', line)
                if node: nodes[node[1]] = json.loads('"' + node[2] + '"')
                if edge: edges.append(edge.groups())
            assert len(nodes) == distinct, "Incomplete TLC graph"
            (cache / f"{name.lower()}-states.json").write_text(json.dumps(list(nodes.values())))
            (cache / f"{name.lower()}-graph.json").write_text(json.dumps(dict(nodes=nodes, edges=edges)))
            graph_hashes[name] = digest(cache / f"{name.lower()}-graph.json")
    assert all(digest(root / path) == sha for path, sha in hashes.items()), "Files changed during checking"
    receipt = dict(complete=not bool(args.only), tlcJarSHA256=digest(jar), hashes=hashes,
                   mutants=mutants, graphHashes=graph_hashes, checks={key: {k: v for k, v in row.items() if k != "trace"} for key, row in results.items()})
    (cache / "run.json").write_text(json.dumps(receipt, indent=2) + "\n")
    if args.record:
        evidence = directory / "results"
        evidence.mkdir(exist_ok=True)
        (evidence / "run.json").write_text(json.dumps(receipt, indent=2) + "\n")
        for name, row in results.items():
            (evidence / f"{name}.log").write_text(json.dumps(row, indent=2) + "\n")
        table = ["| Property | Exact-property failing mutant configs |", "| --- | --- |"]
        table += [f"| {target} | {', '.join(names)} |" for target, names in sorted(mutants.items())]
        (evidence / "MUTANTS.md").write_text("\n".join(table) + "\n")
