import argparse
import collections
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import time
from admission_source import check_admission
from f5_conformance import check_f5_runtime
from f5_checks import EXPECTED as F5_EXPECTED, check_mutant_coverage, check_reachability, valid_result, render_receipt, cross_kill, check_temporal_controls
from supervision import Supervisor

ROOT = Path(__file__).resolve().parents[2]
SPEC = ROOT / "formal/speech-queue"
sys.path.insert(0, str(ROOT / "formal"))
from tlc_support import tlc_jar
from graph_retention import graph_run


def check(runner, f5_only=False, receipt=False):
    with graph_run(ROOT / ".build.noindex/formal-speech-queue", prefix=f"run-{os.getpid()}-") as run:
        check_run(runner, run, f5_only, receipt)


def check_run(runner, RUN, f5_only=False, receipt=False):
    # Focused mode still reads Fixed for reachability; the other graphs feed full replay.
    graphs = {"F5PauseFixed"} if f5_only else {
        "Current", "History", "QueueAdmissionFixed", "F5PauseFixed", "F5PauseFixedTranscribing"}
    EXPECTED = {"StaleClear": "StaleCannotAdvance", "Current": None, "StaleNext": "StaleCannotAdvance", "StopLeaves": "StopClearsQueues",
                "History": None, "MutableTerminal": "FirstAcceptedTerminalImmutable",
                "AdmissionCurrent": None, "AdmissionFinding": "NonemptySelectionDoesNotStop", "AdmissionProposed": None,
                "AdmissionOlderMatch": "EveryQueuedMatchStops", "QueueAdmissionFixed": None,
                "QueueAdmissionClear": "NoSilentClear", "QueueAdmissionDuplicate": "NoDuplicateIdentity", "QueueAdmissionStopLeaves": "StopClearsAll",
                "QueueAdmissionF5Clears": "F5KeepsQueue", "QueueAdmissionFreshClears": "NoSilentClear",
                "QueueAdmissionInferredPlaying": "NoBlindAdvance",
                **F5_EXPECTED}
    check_mutant_coverage(SPEC)
    check_temporal_controls()
    configs = sorted(SPEC.glob("*.cfg"))
    assert {p.stem for p in configs} == set(EXPECTED), "Every config needs an explicit expected result"
    if f5_only:
        configs = [config for config in configs if config.stem in F5_EXPECTED]
    jar = tlc_jar()
    lock = json.loads((ROOT / "formal/tlc.lock.json").read_text())
    jar_hash = hashlib.sha256(jar.read_bytes()).hexdigest()
    assert jar_hash == lock["sha256"], "Pinned TLC checksum mismatch"
    print(f"TLC pin: {lock['version']}; sha256={jar_hash}; path={jar}", flush=True)
    sources = [SPEC / "F5Pause.tla", SPEC / "check.py", SPEC / "f5_checks.py", SPEC / "cross_tlc.py",
               ROOT / "formal/tlc.lock.json", ROOT / "formal/tlc_support.py", *configs]
    sources += [SPEC / "f5_conformance.py", *[ROOT / path for path in (
        "src/tts.ts", "src/f5-capture.ts", "src/socket-handlers.ts", "src/socket-protocol.ts", "src/selection-read-queue.ts",
        "src/recording-jobs.ts", "src/recording-take-queue.ts", "src/recording-state.ts", "formal/corpus_support.py",
        "flow-bar/Sources/VoiceBar/VoiceBarCommandRouter.swift", "flow-bar/Sources/VoiceBar/VoiceBarApp.swift",
        "flow-bar/Sources/VoiceBarUI/VoiceState.swift", "flow-bar/Tests/VoiceBarTests/F5PauseConformanceTests.swift",
        "src/__tests__/tts-long-read-runtime.test.ts", "src/__tests__/tts-pause.test.ts",
        "src/__tests__/socket-handlers-idempotency.test.ts", "src/__tests__/socket-residency.test.ts",
        "src/__tests__/setup/recording-jobs-fixture.ts", "src/__tests__/whisper-residency.test.ts",
        "src/__tests__/update-gate-round1.test.ts", "src/__tests__/error-recovery.test.ts", "src/__tests__/click2-groundwork.test.ts",
        "src/__tests__/recording-review-regressions.test.ts", "src/__tests__/test-safety-lifecycle.test.ts", "src/__tests__/mcp-handler.test.ts",
        "src/__tests__/pause-ask.test.ts",
        "src/__tests__/update-gate-installer-participant.test.ts", "src/__tests__/update-gate-installer-short-holder.test.ts",
        "flow-bar/Tests/VoiceBarUITests/PlaybackPauseTests.swift",
        "formal/speech-queue/F5-IMPLEMENTATION.md")]]
    sources += [SPEC / "check.sh", ROOT / "formal/setup-tlc.py",
                ROOT / "formal/graph_retention.py", SPEC / "test_graph_retention.py"]
    hashes = {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest() for path in sources}
    rows = []
    timings = {}
    def stage(name, started):
        timings[name] = round(time.monotonic() - started, 3)
        (RUN / "timings.json").write_text(json.dumps(timings, indent=2) + "\n")
        print(f"STAGE {name}: {timings[name]:.3f}s", flush=True)
    print(f"Evidence: {RUN}", flush=True)
    started = time.monotonic()
    for config in configs:
        name = config.stem
        cmd = ["nice", "-n", "19", "java", "-Xmx512m", "-XX:+UseParallelGC", "-cp", str(jar), "tlc2.TLC", "-noGenerateSpecTE", "-workers", "1", "-fp", "0", "-seed", "1", "-lncheck", "final",
               "-metadir", str(RUN / name), "-config", str(config)]
        if name in graphs:
            cmd += ["-dump", "dot,actionlabels", str(RUN / f"{name}.dot")]
        module = "F5Pause" if name.startswith("F5Pause") else "QueueAdmission" if name.startswith("QueueAdmission") else "Admission" if name.startswith("Admission") else "History" if name in {"History", "MutableTerminal"} else "SpeechQueue"
        status = runner.run([*cmd, str(SPEC / f"{module}.tla")], RUN / f"{name}.log", 90, cwd=ROOT,
                            env=os.environ)
        output = (RUN / f"{name}.log").read_text()
        if config == configs[0]:
            jar_version = next(line for line in output.splitlines() if line.startswith("TLC2 Version"))
            print(f"{jar_version}; sha256={jar_hash}", flush=True)
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
                   ("Invariant ", "Temporal propert", "Model checking completed.",
                    "states generated,", "The depth of", "Progress(", "AutoPauseNeverStuck |->", "Back to state", "Stuttering"))]
        rows.append(dict(name=name, expected=invariant, actual=actual, generated=int(counts[1]),
                         distinct=int(counts[2]), depth=measured_depth, excerpt=excerpt))
        print(f"{name}: {actual}; {counts[0]}; depth {measured_depth}", flush=True)
    stage("isolated_tlc", started)
    started = time.monotonic()
    # M1 allowance: 24 unchanged 90 s case limits plus 240 s of matrix overhead.
    with Supervisor(2400) as cross_runner:
        cross = cross_kill(RUN, cross_runner,
            ["nice", "-n", "19", "java", "-Xmx3072m", "-XX:+UseParallelGC", "-cp", str(jar),
             "tlc2.TLC", "-noGenerateSpecTE", "-workers", "4", "-fp", "0", "-seed", "1"], SPEC)
    # Matrix time belongs to its own budget; preserve the original gate's remaining 880 s.
    runner.deadline += time.monotonic() - started
    stage("cross_kill", started)
    started = time.monotonic()
    check_reachability(RUN)
    assert all(hashlib.sha256((ROOT / path).read_bytes()).hexdigest() == digest
               for path, digest in hashes.items()), "Sources changed during TLC"
    assert hashlib.sha256(jar.read_bytes()).hexdigest() == jar_hash, "Pinned TLC changed during checking"
    (RUN / "results.json").write_text(json.dumps(dict(rows=rows, cross=cross, sourceSHA256=hashes,
        tlcJarSHA256=jar_hash, tlcVersion=jar_version, tlcRelease=lock["version"]), indent=2) + "\n")
    if receipt:
        document = SPEC / "F5PAUSE-TLC.md"
        before, separator, rest = document.read_text().partition("<!-- TLC-RESULTS-START -->")
        assert separator and "<!-- TLC-RESULTS-END -->" in rest, "Receipt markers missing"
        after = rest.split("<!-- TLC-RESULTS-END -->", 1)[1]
        document.write_text(before + separator + "\n" + render_receipt(rows, cross) + "<!-- TLC-RESULTS-END -->" + after)
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
    stage("reachability_and_runtime_replays", started)
    print(f"PASS: queue/History runtime and real Swift/daemon admission conformance; {sum(row['expected'] is not None for row in rows)} expected counterexamples")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--f5-only", action="store_true", help="Focused F5 TLC, without the existing conformance replays")
    parser.add_argument("--receipt", action="store_true", help="Regenerate TLC tables from this run")
    args = parser.parse_args()
    with Supervisor(880) as runner:
        check(runner, args.f5_only, args.receipt)
