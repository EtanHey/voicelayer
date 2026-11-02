"""Project existing F5 queue/timing obligations onto real daemon and VoiceState events."""
import json
import os
import re
from pathlib import Path


def check_speech_data_runtime(run, runner):
    root = Path(__file__).resolve().parents[2]
    cases = set()
    for name in ("F5PauseFixed", "F5PauseFixedTranscribing"):
        for line in (run / f"{name}.dot").read_text().splitlines():
            node = re.match(r'-?\d+ \[label="((?:\\.|[^"\\])*)"', line)
            if not node:
                continue
            label = json.loads('"' + node[1] + '"')
            phase = re.search(r'speech \|-> "(\w+)"', label)
            queued = re.search(r'queued \|-> (\d+)', label)
            if phase and queued and phase[1] in {"preparing", "playing", "paused", "parked_preparing"}:
                cases.add(("parked" if phase[1] in {"paused", "parked_preparing"} else phase[1], int(queued[1])))
    assert cases == {(phase, queued) for phase in ("preparing", "playing", "parked") for queued in range(3)}, cases
    cases_path = run / "speech-data-cases.json"
    cases_path.write_text(json.dumps([dict(phase=phase, queued=queued) for phase, queued in sorted(cases)]))
    env = {**os.environ, "VOICELAYER_SPEECH_CASES": str(cases_path),
           "VOICELAYER_SPEECH_WIRE": str(run / "speech-data-wire.json"),
           "VOICELAYER_SPEECH_TIMING_WIRE": str(run / "speech-timing-wire.json")}
    def execute(command, log):
        status = runner.run(["nice", "-n", "19", *command], run / log, 900, cwd=root, env=env)
        output = (run / log).read_text()
        print(output, end="", flush=True)
        return status, output
    bun = ["bun", "test", "src/__tests__/tts-long-read-runtime.test.ts", "-t", "F-speech"]
    status, output = execute(bun, "speech-data-daemon.log")
    assert status == 0 and "QueuedCountExcludesCurrent replayed 9" in output and " 0 fail" in output
    status, output = execute(["swift", "test", "--package-path", "flow-bar", "--scratch-path", ".build.noindex/swift",
                              "--filter", "SpeechDataConformanceTests"], "speech-data-swift.log")
    assert status == 0 and "Speech data replayed 9 real queue snapshots and first speaking frame" in output
    source = root / "src/tts.ts"
    fixed = source.read_text()
    mutants = [
        ("QueuedCountExcludesCurrent", 'priority: this.preparing.job.priority,\n        is_current: true,',
         'priority: this.preparing.job.priority,\n        is_current: false,'),
        ("TimingNeverBlankWhilePlaying", '        initial_timing: initialPlaybackTiming(next.metadata.text, durationMs, next.metadata.wordBoundaries, next.metadata.alignedWords),\n', ''),
    ]
    results = []
    for prop, before, after in mutants:
        assert fixed.count(before) == 1, f"Mutant anchor drift: {prop}"
        try:
            source.write_text(fixed.replace(before, after))
            status, output = execute([*bun[:-1], prop], f"speech-data-mutant-{prop}.log")
            assert status != 0 and prop in output and "(fail)" in output, f"Surviving runtime mutant: {prop}"
            results.append(dict(property=prop, mutation=after or "omit initial_timing", expected="FAIL", actual="FAIL", exit=status))
        finally:
            source.write_text(fixed)
    (run / "speech-data-results.json").write_text(json.dumps(dict(projected_cases=len(cases),
        native_queue_frames=len(cases), native_first_speaking_frames=1, mutants=results), indent=2) + "\n")
    print(f"PASS: speech data {len(cases)} real queue frames + first speaking frame; both runtime mutants killed", flush=True)
