"""Project TLC capture-end edges onto R2-01 scenarios; retain distinct ownership/gesture/cursor/take cases.

Queue-count presentation and initial-timing are separate R2-03/R2-05 work. Their Current traces remain
explicitly enumerated by the gate, but this replay asserts R2-01 ownership/cursor/capture behaviour only.
"""
import json
import re
from pathlib import Path


def capture_cases(run):
    # The model owns capture identities; normalize only the active identities for this read loan.
    # This is a scenario projection, not an implementation of TLC's transition relation.
    import sys
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    from corpus_support import state
    from f5_checks import CURRENT
    cases, graph_counts = {}, {}
    for name in ("F5PauseFixed", "F5PauseFixedTranscribing"):
        labels, edges = {}, []
        for line in (run / f"{name}.dot").open():
            node = re.match(r'(-?\d+) \[label="((?:\\.|[^"\\])*)"', line)
            edge = re.match(r'(-?\d+) -> (-?\d+) ', line)
            if node:
                labels[node[1]] = state(json.loads('"' + node[2] + '"'))
            elif edge:
                edges.append(edge.groups())
        reported = re.findall(r"(\d+) distinct states found", (run / f"{name}.log").read_text())
        assert reported and len(labels) == int(reported[-1]), f"Incomplete {name} graph"
        selected = 0
        for source, target in edges:
            before, after = labels[source], labels[target]
            old, new = before["s"], after["s"]
            event = new["event"]
            if not event.startswith("end_") or not (old["owner"] in {"f5", "user"} or old["stopWon"]):
                continue
            # DOT includes stuttering/self edges retaining the previous end-event label.
            if old == new:
                continue
            caps = old["caps"]
            active = [i for i, phase in enumerate(caps) if phase != "idle"]
            ended = [i for i in active if new["caps"][i] == "idle"]
            assert len(ended) == 1 and len(active) in {1, 2}, (source, target, old, new)
            selected += 1
            initial = "preparing" if old["speech"] == "parked_preparing" or old["timing"] == "none" else "playing"
            # A user owner can arise before F5 or through the approved manual conversion while recording.
            ownership = [(False, False)] if old["owner"] != "user" else [(True, False), (False, True)]
            for manual_before, manual in ownership:
                row = dict(initial=initial, press=before["pressPos"], manualBefore=manual_before,
                           manual=manual, stopped=old["stopWon"],
                           outcome=event.removeprefix("end_").removesuffix("_auto_resume"),
                           queued=old["queued"], takes=len(active), ending=active.index(ended[0]))
                for gesture in ("tap", "hold", "double"):
                    case = {**row, "gesture": gesture}
                    cases[json.dumps(case, sort_keys=True)] = case
        graph_counts[name] = dict(states=len(labels), edges=len(edges), capture_end_edges=selected)
        assert selected, f"No read/capture settlement edges in {name}"
    counterexamples = {}
    for name in CURRENT:
        log = (run / f"{name}.log").read_text()
        bodies = re.findall(r"State \d+:[^\n]*\n(.*?)(?=\nState \d+:|\n\d+ states generated|\Z)", log, re.S)
        states = [state(body) for body in bodies]
        assert states, f"Missing actual Current trace: {name}"
        events = [item["s"]["event"] for item in states]
        counterexamples[name] = events
        edge = next((i for i, item in enumerate(states) if item["f5Saw"] != "none"), None)
        prior = states[max(0, edge - 1)] if edge is not None else states[0]
        seen = prior["s"]["speech"]
        overlapping = any(item["transcribingBefore"] for item in states)
        initial = "preparing" if seen in {"none", "preparing", "parked_preparing"} else "playing"
        row = dict(initial=initial, press=states[edge]["pressPos"] if edge is not None else 0,
                   manualBefore=prior["s"]["owner"] == "user", manual=False, stopped=False,
                   outcome="cancelled" if "f5_cancel_transcribing" in events else "timeout",
                   queued=0, takes=2 if overlapping else 1, ending=0,
                   gesture="hold" if any("release" in event or "hold" in event for event in events) else "tap",
                   current=name, current_events=events)
        cases["current-" + name] = row
    (run / "f5-current-prefixes.json").write_text(json.dumps(counterexamples, indent=2))
    (run / "f5-projection-counts.json").write_text(json.dumps(graph_counts, indent=2))
    rows = sorted(cases.values(), key=lambda row: json.dumps(row, sort_keys=True))
    assert {row["outcome"] for row in rows} == {"pasted", "empty", "failed", "cancelled", "timeout"}
    assert any(row["press"] >= 3 and not row["manual"] and not row["stopped"] for row in rows)
    assert {row["ending"] for row in rows if row["takes"] == 2} == {0, 1}
    assert any(row["initial"] == "preparing" and row["manual"] for row in rows)
    path = run / "f5-cases.json"
    path.write_text(json.dumps(rows))
    print(f"F5 R2-01 projection: {graph_counts} -> {len(rows)} scenarios; all capture-end edges projected, both N6 settlement orders, all Current prefixes", flush=True)
    return path


def check_f5_runtime(run, runner):
    import os
    root = Path(__file__).resolve().parents[2]
    cases = capture_cases(run)
    env = {**os.environ, "VOICELAYER_F5_CASES": str(cases), "VOICELAYER_F5_WIRE": str(run / "f5-wire.json")}
    daemon_wire = run / "f5-daemon-wire.json"
    commands = [
        (["swift", "test", "--package-path", "flow-bar", "--scratch-path", ".build.noindex/swift", "--filter", "F5PauseConformanceTests|VoiceBarCommandRouterTests.testRealGestureStartsN6AfterALockedTakeBeginsTranscribing|PlaybackPauseTests.testPreparingPauseOwnerIsControllableBeforeAFirstChunkExists"], "f5-swift.log"),
        (["bun", "test", "src/__tests__/tts-long-read-runtime.test.ts"], "f5-daemon.log"),
        (["bun", "test", "src/__tests__/tts-pause.test.ts"], "f5-settlement.log"),
        (["bun", "test", "src/__tests__/socket-handlers-idempotency.test.ts", "src/__tests__/socket-residency.test.ts", "src/__tests__/whisper-residency.test.ts", "src/__tests__/update-gate-round1.test.ts", "src/__tests__/error-recovery.test.ts", "src/__tests__/click2-groundwork.test.ts", "src/__tests__/recording-review-regressions.test.ts", "src/__tests__/test-safety-lifecycle.test.ts", "src/__tests__/mcp-handler.test.ts", "src/__tests__/pause-ask.test.ts", "src/__tests__/update-gate-installer-participant.test.ts", "src/__tests__/update-gate-installer-short-holder.test.ts"], "f5-socket-idempotency.log"),
    ]
    for command, name in commands:
        status = runner.run(["nice", "-n", "19", *command], run / name, 900, cwd=root, env={**env, **({"VOICELAYER_F5_DAEMON_WIRE": str(daemon_wire)} if name == "f5-daemon.log" else {})})
        print((run / name).read_text(), end="", flush=True)
        assert status == 0, f"F5 runtime divergence: {name}"
        output = (run / name).read_text()
        if name == "f5-swift.log":
            assert f"Replayed {len(json.loads(cases.read_text()))} TLC F5 scenarios" in output, "Native replay skipped"
        elif name == "f5-daemon.log":
            assert f"Replayed {len(json.loads(cases.read_text()))} TLC F5 native command scenarios" in output, "Daemon replay skipped"
        else:
            assert " 0 fail" in output and " 0 pass" not in output, "Settlement guards skipped"

    paired_env = {**env, "VOICELAYER_F5_DAEMON_WIRE": str(daemon_wire)}
    native_test = "F5PauseConformanceTests.testRealDaemonSettlementFramesProjectResumedReadToSpeaking"
    native_command = ["nice", "-n", "19", "swift", "test", "--package-path", "flow-bar",
                      "--scratch-path", ".build.noindex/swift", "--filter", native_test]
    status = runner.run(native_command, run / "f5-native-projection.log", 900, cwd=root, env=paired_env)
    output = (run / "f5-native-projection.log").read_text()
    print(output, end="", flush=True)
    assert status == 0 and f"Projected {len(json.loads(cases.read_text()))} real daemon F5 scenarios" in output, "Native daemon projection skipped or diverged"

    # Restore the exact old identity-retirement guard in a private package, never the checked sources.
    import shutil
    import tempfile
    with tempfile.TemporaryDirectory(prefix="f5-resume-mutant-", dir=root / ".build.noindex") as directory:
        package = Path(directory) / "flow-bar"
        package.mkdir()
        shutil.copy2(root / "flow-bar/Package.swift", package / "Package.swift")
        for name in ("Sources", "Tests"):
            shutil.copytree(root / "flow-bar" / name, package / name)
        source = package / "Sources/VoiceBarUI/VoiceState.swift"
        current = source.read_text()
        guard = "} else if mode != .speaking, !keepsSelectionReadThroughCapture {"
        assert current.count(guard) == 1, "Resume identity mutant no longer matches its guard"
        source.write_text(current.replace(guard, "} else if mode != .speaking {"))
        mutant_command = ["nice", "-n", "19", "swift", "test", "--package-path", str(package),
                          "--scratch-path", str(Path(directory) / "swift"), "--filter", native_test]
        status = runner.run(mutant_command, run / "f5-native-resume-mutant.log", 900, cwd=root, env=paired_env)
        output = (run / "f5-native-resume-mutant.log").read_text()
        assert status != 0 and "XCTAssertEqual failed" in output and "native daemon resumed projection row" in output, "Old-drop mutant must fail native speaking projection"
        failures = output.count("native daemon resumed projection row")
        (run / "f5-native-mutant.json").write_text(json.dumps({"property": "NativeResumedReadIsSpeaking",
            "mutant": "old mode != speaking identity retirement", "expected": "FAIL", "actual": "FAIL",
            "native_projection_failures": failures}, indent=2) + "\n")
        print(f"NativeResumedReadIsSpeaking mutant: expected FAIL, actual FAIL; {failures} resumed projections rejected", flush=True)


def check_clone_resume_runtime(run, runner):
    """Same owned clone frames go through the actual native state, including the restored bug."""
    import os
    from speech_data_conformance import mutant_copy
    root = Path(__file__).resolve().parents[2]
    wire = run / "f5-clone-wire.json"
    env = {**os.environ, "VOICELAYER_F5_CLONE_WIRE": str(wire)}
    bun = ["nice", "-n", "19", "bun", "test", "src/__tests__/tts-long-read-runtime.test.ts", "-t", "F-resume-clone"]
    native = ["nice", "-n", "19", "swift", "test", "--package-path", "flow-bar",
              "--scratch-path", ".build.noindex/swift", "--filter",
              "F5PauseConformanceTests.testCloneShortChunkedDaemonFramesResumeAtPausedWord"]
    for command, name in [(bun, "f5-clone-daemon.log"), (native, "f5-clone-native.log")]:
        status = runner.run(command, run / name, 900, cwd=root, env=env)
        output = (run / name).read_text()
        print(output, end="", flush=True)
        assert status == 0, f"Clone resume conformance diverged: {name}"
    rows = json.loads(wire.read_text())
    assert len(rows) == 32 and sum(row["resumes"] for row in rows) == 20, "Clone replay was skipped or incomplete"
    assert "Projected 32 real daemon F5 scenarios" in (run / "f5-clone-native.log").read_text(), "Clone native projection skipped"
    fixed = (root / "src/tts.ts").read_text()
    guard = "const isLastChunk = !longRead || longRead.chunk_index === longRead.chunk_count - 1;"
    assert fixed.count(guard) == 1, "Chunk-end mutant no longer matches its guard"
    mutant_wire = run / "f5-clone-mutant-wire.json"
    mutant_env = {**env, "VOICELAYER_F5_CLONE_WIRE": str(mutant_wire)}
    with mutant_copy(root, run) as scratch:
        (scratch / "src/tts.ts").write_text(fixed.replace(guard, "const isLastChunk = true;"))
        command = [*bun[:-1], "F-resume-clone short chunked F5 4000/auto"]
        status = runner.run(command, run / "f5-clone-mutant.log", 900, cwd=scratch, env=mutant_env)
        output = (run / "f5-clone-mutant.log").read_text()
        assert status != 0 and "error: ClonePauseKeepsPressWord" in output and " 1 fail" in output, "Chunk-end mutant survived daemon guard"
    status = runner.run(native, run / "f5-clone-native-mutant.log", 900, cwd=root, env=mutant_env)
    output = (run / "f5-clone-native-mutant.log").read_text()
    assert status != 0 and "native daemon resumed projection row" in output and "XCTAssertEqual failed" in output, "Chunk-end mutant survived native projection"
    assert (root / "src/tts.ts").read_text() == fixed, "Tracked source changed during clone mutant"
    (run / "f5-clone-mutant.json").write_text(json.dumps(dict(
        property="ClonePauseKeepsPressWord / NativeResumedReadIsSpeaking",
        mutant="treat every chunk end as whole-read end", expected="FAIL", actual="FAIL",
        clone_scenarios=len(rows), expected_resumes=sum(row["resumes"] for row in rows),
        native_projection_failures=output.count("native daemon resumed projection row")), indent=2) + "\n")
    print("PASS: 32 clone short/long boundary/interior scenarios; 20 native resumes; restored chunk-end mutant FAILS daemon AND native", flush=True)
