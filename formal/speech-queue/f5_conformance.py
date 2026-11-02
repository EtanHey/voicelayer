"""Project TLC capture-end states onto R2-01 runtime scenarios; retain every distinct ownership/gesture/cursor case.

Queue-count presentation and initial-timing are separate R2-03/R2-05 work. Their Current traces remain
explicitly enumerated by the gate, but this replay asserts R2-01 ownership/cursor/capture behaviour only.
"""
import json
import re
from pathlib import Path


def capture_cases(run):
    labels = {}
    for line in (run / "F5PauseFixed.dot").read_text().splitlines():
        node = re.match(r'(-?\d+) \[label="((?:\\.|[^"\\])*)"', line)
        if node:
            labels[node[1]] = json.loads('"' + node[2] + '"')
    def value(label, key):
        match = re.search(rf'\b{key} = ("[^"\n]*"|TRUE|FALSE|\d+)', label)
        assert match, key
        token = match[1]
        return token == "TRUE" if token in {"TRUE", "FALSE"} else json.loads(token)
    cases = {}
    for label in labels.values():
        event = value(label, "event")
        if not event.startswith("end_"):
            continue
        saw = value(label, "f5Saw")
        if saw not in {"playing", "paused", "preparing"}:
            continue
        owner = value(label, "endOwner")
        row = dict(initial=saw, press=value(label, "pausedAt") * 2 + 1,
                   manual=saw != "paused" and owner == "user", stopped=value(label, "stopInCapture"),
                   outcome=event.removeprefix("end_").removesuffix("_auto_resume"),
                   queued=value(label, "queued"))
        # End-state held is intentionally ignored: physical key state is independently exercised below.
        for gesture in ("tap", "hold", "double"):
            case = {**row, "gesture": gesture}
            cases[json.dumps(case, sort_keys=True)] = case
    # Every Current counterexample contributes its actual input prefix, projected onto this lane.
    # R2-03/05 prefixes prepare/start speech here; presentation/timing assertions stay with their lane.
    from f5_checks import CURRENT
    counterexamples = {}
    for name in CURRENT:
        log = (run / f"{name}.log").read_text()
        states = re.findall(r"State \d+:[^\n]*\n(.*?)(?=\nState \d+:|\n\d+ states generated|\Z)", log, re.S)
        assert states, f"Missing actual Current trace: {name}"
        events = [value(state, "event") for state in states]
        counterexamples[name] = events
        failing = states[-1]
        pause = next((state for state in states if "f5_hold_ignored" in state or "f5_tap_stops" in state), None)
        initial = "paused" if "user_pause" in events else value(pause, "f5Saw") if pause else (
            "playing" if "start_playback" in events else "preparing")
        row = dict(initial=initial, press=value(failing, "pos"), manual=False, stopped=False,
                   outcome="empty" if "hold_release" in events else "timeout", queued=0,
                   gesture="hold" if pause else "tap", current=name, current_events=events)
        cases["current-" + name] = row
    (run / "f5-current-prefixes.json").write_text(json.dumps(counterexamples, indent=2))
    assert cases
    rows = sorted(cases.values(), key=lambda row: json.dumps(row, sort_keys=True))
    assert {row["outcome"] for row in rows} == {"pasted", "empty", "failed", "cancelled", "timeout"}
    assert any(row["press"] >= 3 and not row["manual"] and not row["stopped"] for row in rows)
    path = run / "f5-cases.json"
    path.write_text(json.dumps(rows))
    print(f"F5 R2-01 projection: {len(labels)} TLC states -> {len(rows)} capture scenarios, every outcome/gesture/owner/cursor", flush=True)
    return path


def check_f5_runtime(run, runner):
    import os
    root = Path(__file__).resolve().parents[2]
    cases = capture_cases(run)
    env = {**os.environ, "VOICELAYER_F5_CASES": str(cases), "VOICELAYER_F5_WIRE": str(run / "f5-wire.json")}
    commands = [
        (["swift", "test", "--package-path", "flow-bar", "--scratch-path", ".build.noindex/swift", "--filter", "F5PauseConformanceTests|VoiceBarCommandRouterTests.testRealGestureStartsN6AfterALockedTakeBeginsTranscribing|PlaybackPauseTests.testPreparingPauseOwnerIsControllableBeforeAFirstChunkExists"], "f5-swift.log"),
        (["bun", "test", "src/__tests__/tts-long-read-runtime.test.ts", "-t", "TLC F5"], "f5-daemon.log"),
        (["bun", "test", "src/__tests__/tts-pause.test.ts", "-t", "R2-01"], "f5-settlement.log"),
    ]
    for command, name in commands:
        status = runner.run(["nice", "-n", "19", *command], run / name, 900, cwd=root, env=env)
        print((run / name).read_text(), end="", flush=True)
        assert status == 0, f"F5 runtime divergence: {name}"
        output = (run / name).read_text()
        if name == "f5-swift.log":
            assert f"Replayed {len(json.loads(cases.read_text()))} TLC F5 scenarios" in output, "Native replay skipped"
        elif name == "f5-daemon.log":
            assert f"Replayed {len(json.loads(cases.read_text()))} TLC F5 native command scenarios" in output, "Daemon replay skipped"
        else:
            assert " 0 fail" in output and " 0 pass" not in output, "Settlement guards skipped"
