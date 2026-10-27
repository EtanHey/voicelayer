import collections
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SPEC = ROOT / "formal/speech-queue"
OUT = ROOT / ".build.noindex/formal-speech-queue"
OUT.mkdir(parents=True, exist_ok=True)
RUN = Path(tempfile.mkdtemp(prefix="run-", dir=OUT))
EXPECTED = {"Current": None, "StaleNext": "StaleCannotAdvance", "StopLeaves": "StopClearsQueues",
            "History": None, "MutableTerminal": "FirstAcceptedTerminalImmutable"}
configs = sorted(SPEC.glob("*.cfg"))
assert {p.stem for p in configs} == set(EXPECTED), "Every config needs an explicit expected result"
print(f"Evidence: {RUN}", flush=True)
for config in configs:
    name = config.stem
    cmd = [str(Path.home() / ".local/bin/tlc"), "-workers", "1", "-fp", "0", "-seed", "1",
           "-metadir", str(RUN / name), "-config", str(config)]
    if EXPECTED[name] is None:
        cmd += ["-dump", "dot,actionlabels", str(RUN / f"{name}.dot")]
    module = "History" if name in {"History", "MutableTerminal"} else "SpeechQueue"
    run = subprocess.run(cmd + [str(SPEC / f"{module}.tla")], cwd=ROOT,
                         env={**os.environ, "JAVA_TOOL_OPTIONS": "-Xmx512m"}, capture_output=True, text=True, timeout=90)
    output = run.stdout + run.stderr
    (RUN / f"{name}.log").write_text(output)
    invariant = EXPECTED[name]
    violations = re.findall(r"Invariant (\w+) is violated", output)
    valid = (run.returncode == 12 and violations == [invariant]) if invariant else (
        run.returncode == 0 and "Model checking completed. No error has been found." in output)
    if not valid:
        raise SystemExit(f"Unexpected result for {name}:\n{output}")
    counts = re.search(r"\d+ states generated, \d+ distinct states found", output)
    print(f"{name}: {'PASS' if not invariant else 'EXPECTED violation ' + invariant}; {counts[0] if counts else 'no counts'}", flush=True)

def graph(name, event_pattern, parse_event):
    nodes, edges = {}, []
    for line in (RUN / f"{name}.dot").read_text().splitlines():
        edge = re.match(r"(-?\d+) -> (-?\d+) ", line)
        node = re.match(r'(-?\d+) \[label="((?:\\.|[^"\\])*)"', line)
        if edge:
            edges.append(edge.groups())
        elif node:
            nodes[node[1]] = json.loads('"' + node[2] + '"')
    assert nodes and edges, "TLC graph cannot be empty"
    initial, = [key for key, label in nodes.items() if re.search(r"steps = 0(?:\n|$)", label)]
    paths, adjacent, todo = {initial: []}, collections.defaultdict(list), collections.deque([initial])
    for source, target in edges:
        adjacent[source].append(target)
    while todo:
        source = todo.popleft()
        for target in adjacent[source]:
            if target not in paths:
                paths[target] = paths[source] + [parse_event(re.search(event_pattern, nodes[target])[1])]
                todo.append(target)
    assert len(paths) == len(nodes), "TLC graph has unreachable or unparsed states"
    reported = re.findall(r"(\d+) distinct states found", (RUN / f"{name}.log").read_text())
    assert reported and len(nodes) == int(reported[-1]), "Graph omits model states"
    print(f"{name}: replaying {len(edges)} edges from {len(nodes)} states", flush=True)
    return nodes, edges, paths

nodes, edges, paths = graph("Current", r"event = (\d+)", int)
cases = []
for source, target in edges:
    label = nodes[target]
    number = lambda key: int(re.search(rf"\b{key} \|-> (\d+)", label)[1])
    sequence = lambda key: [int(n) for n in re.findall(r"\d+", re.search(rf"\b{key} \|-> <<(.*?)>>", label)[1])]
    event = int(re.search(r"event = (\d+)", label)[1])
    cases.append(dict(trace=paths[source] + [event], pending=len(sequence("pending")), started=sequence("started"),
                      visible=dict(count=number("count"), current_request_id=str(number("visible")) if number("visible") else None),
                      result=re.search(r'result = "(\w+)"', label)[1]))
assert {row["trace"][-1] for row in cases} == set(range(1, 31)), "Some operations were never explored"
assert any(row["result"] == "full" for row in cases), "Overflow was never explored"
corpus = RUN / "cases.json"
corpus.write_text(json.dumps(cases))
nodes, edges, paths = graph("History", r'event = "(\w+)"', str)
history = RUN / "history.json"
history.write_text(json.dumps([dict(trace=paths[source] + [re.search(r'event = "(\w+)"', nodes[target])[1]],
                                  state=re.search(r'\bstate = "(\w+)"', nodes[target])[1],
                                  moves=int(re.search(r'\bmoves = (\d+)', nodes[target])[1])) for source, target in edges]))
run = subprocess.run(["timeout", "-s", "KILL", "900", "bun", "test", "src/__tests__/speech-queue-model.test.ts", "src/__tests__/speech-history-model.test.ts"], cwd=ROOT,
                     env={**os.environ, "VOICELAYER_SPEECH_QUEUE_MODEL_CASES": str(corpus),
                          "VOICELAYER_SPEECH_HISTORY_MODEL_CASES": str(history)}, capture_output=True, text=True)
(RUN / "conformance.log").write_text(run.stdout + run.stderr)
print(run.stdout + run.stderr, end="", flush=True)
if run.returncode:
    raise SystemExit(run.returncode)
print("PASS: both source conformance checks; three expected counterexamples")
