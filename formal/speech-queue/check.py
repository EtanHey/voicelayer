import argparse
import collections
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import tempfile
from admission_source import check_admission
from f5_conformance import check_f5_runtime
from f5_checks import EXPECTED as F5_EXPECTED, check_mutant_coverage, check_reachability, valid_result, render_receipt
from supervision import Supervisor

ROOT = Path(__file__).resolve().parents[2]
SPEC = ROOT / "formal/speech-queue"


def check(runner, f5_only=False, receipt=False):
    OUT = ROOT / ".build.noindex/formal-speech-queue"
    OUT.mkdir(parents=True, exist_ok=True)
    RUN = Path(tempfile.mkdtemp(prefix=f"run-{os.getpid()}-", dir=OUT))
    for old in sorted(OUT.glob("run-*"), key=lambda path: path.stat().st_mtime, reverse=True)[3:]:
        shutil.rmtree(old)
    EXPECTED = {"StaleClear": "StaleCannotAdvance", "Current": None, "StaleNext": "StaleCannotAdvance", "StopLeaves": "StopClearsQueues",
                "History": None, "MutableTerminal": "FirstAcceptedTerminalImmutable",
                "AdmissionCurrent": None, "AdmissionFinding": "NonemptySelectionDoesNotStop", "AdmissionProposed": None,
                "AdmissionOlderMatch": "EveryQueuedMatchStops", "QueueAdmissionFixed": None,
                "QueueAdmissionClear": "NoSilentClear", "QueueAdmissionDuplicate": "NoDuplicateIdentity", "QueueAdmissionStopLeaves": "StopClearsAll",
                "QueueAdmissionF5Clears": "F5KeepsQueue", "QueueAdmissionFreshClears": "NoSilentClear",
                "QueueAdmissionInferredPlaying": "NoBlindAdvance",
                **F5_EXPECTED}
    check_mutant_coverage(SPEC)
    configs = sorted(SPEC.glob("*.cfg"))
    assert {p.stem for p in configs} == set(EXPECTED), "Every config needs an explicit expected result"
    if f5_only:
        configs = [config for config in configs if config.stem in F5_EXPECTED]
    jar = Path.home() / ".cache/tla/tla2tools.jar"
    assert jar.is_file(), f"Missing TLC jar: {jar}"
    sources = [SPEC / "F5Pause.tla", SPEC / "check.py", SPEC / "f5_checks.py", *configs]
    sources += [SPEC / "f5_conformance.py", *[ROOT / path for path in (
        "src/tts.ts", "src/f5-capture.ts", "src/socket-handlers.ts", "src/socket-protocol.ts", "src/selection-read-queue.ts",
        "flow-bar/Sources/VoiceBar/VoiceBarCommandRouter.swift", "flow-bar/Sources/VoiceBar/VoiceBarApp.swift",
        "flow-bar/Sources/VoiceBarUI/VoiceState.swift", "flow-bar/Tests/VoiceBarTests/F5PauseConformanceTests.swift",
        "src/__tests__/tts-long-read-runtime.test.ts", "src/__tests__/tts-pause.test.ts")]]
    hashes = {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sources}
    rows = []
    print(f"Evidence: {RUN}", flush=True)
    for config in configs:
        name = config.stem
        cmd = ["nice", "-n", "19", "java", "-Xmx512m", "-XX:+UseParallelGC", "-cp", str(jar), "tlc2.TLC", "-workers", "1", "-fp", "0", "-seed", "1",
               "-metadir", str(RUN / name), "-config", str(config)]
        if EXPECTED[name] is None or name == "F5PauseStuck":
            cmd += ["-dump", "dot,actionlabels", str(RUN / f"{name}.dot")]
        module = "F5Pause" if name.startswith("F5Pause") else "QueueAdmission" if name.startswith("QueueAdmission") else "Admission" if name.startswith("Admission") else "History" if name in {"History", "MutableTerminal"} else "SpeechQueue"
        status = runner.run([*cmd, str(SPEC / f"{module}.tla")], RUN / f"{name}.log", 90, cwd=ROOT,
                            env=os.environ)
        output = (RUN / f"{name}.log").read_text()
        invariant = EXPECTED[name]
        if not valid_result(status, output, invariant, config.read_text()):
            raise SystemExit(f"Unexpected result for {name}:\n{output}")
        counts = re.search(r"(\d+) states generated, (\d+) distinct states found", output)
        assert counts, f"Missing TLC state counts: {name}"
        depth = re.search(r"The depth of the complete state graph search is (\d+)", output)
        progress_depth = re.search(r"Progress\((\d+)\)[^\n]* 0 states left on queue\.", output)
        measured_depth = depth[1] if depth else (
            progress_depth[1] + " (TLC completed Progress)" if progress_depth
            and "Checking temporal properties for the complete state space" in output else "not emitted by TLC")
        actual = "FAIL " + invariant if invariant else "PASS"
        excerpt = [line for line in output.splitlines() if any(marker in line for marker in
                   ("Invariant ", "Temporal properties were violated", "Model checking completed.",
                    "states generated,", "The depth of", "Progress(", "AutoPauseNeverStuck |->", "Back to state", "Stuttering"))]
        rows.append(dict(name=name, expected=invariant, actual=actual, generated=int(counts[1]),
                         distinct=int(counts[2]), depth=measured_depth, excerpt=excerpt))
        print(f"{name}: {actual}; {counts[0]}; depth {measured_depth}", flush=True)
    check_reachability(RUN)
    assert all(hashlib.sha256((ROOT / path).read_bytes()).hexdigest() == digest
               for path, digest in hashes.items()), "Sources changed during TLC"
    (RUN / "results.json").write_text(json.dumps(dict(rows=rows, sourceSHA256=hashes,
        tlcJarSHA256=hashlib.sha256(jar.read_bytes()).hexdigest()), indent=2) + "\n")
    if receipt:
        document = SPEC / "F5PAUSE-TLC.md"
        before, separator, rest = document.read_text().partition("<!-- TLC-RESULTS-START -->")
        assert separator and "<!-- TLC-RESULTS-END -->" in rest, "Receipt markers missing"
        after = rest.split("<!-- TLC-RESULTS-END -->", 1)[1]
        document.write_text(before + separator + "\n" + render_receipt(rows) + "<!-- TLC-RESULTS-END -->" + after)
    if f5_only:
        print("PASS: F5 fixed contract, current failures, and every exact-property mutant (no runtime replay)", flush=True)
        return

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
    status = runner.run(["bun", "test", "src/__tests__/speech-queue-model.test.ts", "src/__tests__/speech-history-model.test.ts"], RUN / "conformance.log", 900, cwd=ROOT,
                        env={**os.environ, "VOICELAYER_SPEECH_QUEUE_MODEL_CASES": str(corpus),
                             "VOICELAYER_SPEECH_HISTORY_MODEL_CASES": str(history)})
    print((RUN / "conformance.log").read_text(), end="", flush=True)
    if status:
        raise SystemExit(status)
    check_admission(RUN, runner)
    check_f5_runtime(RUN, runner)
    assert all(hashlib.sha256((ROOT / path).read_bytes()).hexdigest() == digest
               for path, digest in hashes.items()), "Sources changed during runtime conformance"
    print(f"PASS: queue/History runtime and real Swift/daemon admission conformance; {sum(row['expected'] is not None for row in rows)} expected counterexamples")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--f5-only", action="store_true", help="Focused F5 TLC, without the existing conformance replays")
    parser.add_argument("--receipt", action="store_true", help="Regenerate TLC tables from this run")
    args = parser.parse_args()
    with Supervisor(880) as runner:
        check(runner, args.f5_only, args.receipt)
