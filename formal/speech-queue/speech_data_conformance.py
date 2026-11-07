"""Project F5 queue/timing obligations, including Resume, onto real daemon/VoiceState events."""
from contextlib import contextmanager
import json
import os
import re
import shutil
import sys
import tempfile
from pathlib import Path


def speech_cases(run):
    cases, resumes, witnesses, counts = set(), set(), {}, {}
    for name in ("F5PauseFixed", "F5PauseFixedTranscribing"):
        labels = {}
        with (run / f"{name}.dot").open() as graph:
            for line in graph:
                node = re.match(r'(-?\d+) \[label="((?:\\.|[^"\\])*)"', line)
                if not node:
                    continue
                label = json.loads('"' + node[2] + '"')
                phase = re.search(r'speech \|-> "(\w+)"', label)
                queued = re.search(r'queued \|-> (\d+)', label)
                owner = re.search(r'owner \|-> "(\w+)"', label)
                event = re.search(r'event \|-> "(\w+)"', label)
                assert phase and queued and owner and event, name
                labels[node[1]] = (phase[1], int(queued[1]), owner[1], event[1])
                if phase[1] in {"preparing", "playing", "paused", "parked_preparing"}:
                    cases.add(("parked" if phase[1] in {"paused", "parked_preparing"} else phase[1], int(queued[1])))
        selected = 0
        with (run / f"{name}.dot").open() as graph:
            for line in graph:
                edge = re.match(r'(-?\d+) -> (-?\d+) ', line)
                if not edge:
                    continue
                before, after = labels[edge[1]], labels[edge[2]]
                if before[0] not in {"paused", "parked_preparing"} or after[0] != "playing":
                    continue
                manual = before[2] == "user" and after[3] == "user_play"
                auto = before[2] == "f5" and after[3].endswith("_auto_resume")
                if not (manual or auto):
                    continue
                assert before[1] == after[1], (name, before, after)
                case = ("resume_manual" if manual else "resume_f5", after[1])
                resumes.add(case)
                witnesses.setdefault(str(case), dict(graph=name, source=edge[1], target=edge[2], before=before, after=after))
                selected += 1
        assert selected, f"No Resume edges in {name}"
        counts[name] = selected
    assert cases == {(phase, queued) for phase in ("preparing", "playing", "parked") for queued in range(3)}, cases
    assert resumes == {(phase, queued) for phase in ("resume_manual", "resume_f5") for queued in range(3)}, resumes
    rows = [dict(phase=phase, queued=queued, holdExit=False) for phase, queued in sorted(cases)]
    # Physical player exit is below the logical model; replay both exit orders for each Resume edge projection.
    rows += [dict(phase=phase, queued=queued, holdExit=hold) for phase, queued in sorted(resumes) for hold in (False, True)]
    (run / "speech-data-projection.json").write_text(json.dumps(dict(resume_edges=counts, witnesses=witnesses), indent=2) + "\n")
    return rows


@contextmanager
def mutant_copy(root, parent):
    """Tracked source is never writable through a mutant, even if the supervisor is killed."""
    with tempfile.TemporaryDirectory(prefix="speech-mutant-", dir=parent) as directory:
        scratch = Path(directory) / "tree"
        shutil.copytree(root, scratch, ignore=shutil.ignore_patterns(
            ".git", ".build.noindex", ".worktrees", "docs.local", "node_modules", ".test-tmp", "__pycache__"))
        (scratch / "node_modules").symlink_to(root / "node_modules", target_is_directory=True)
        yield scratch


def check_speech_data_runtime(run, runner):
    root = Path(__file__).resolve().parents[2]
    cases = speech_cases(run)
    cases_path = run / "speech-data-cases.json"
    cases_path.write_text(json.dumps(cases))
    env = {**os.environ, "VOICELAYER_SPEECH_CASES": str(cases_path),
           "VOICELAYER_SPEECH_WIRE": str(run / "speech-data-wire.json"),
           "VOICELAYER_SPEECH_TIMING_WIRE": str(run / "speech-timing-wire.json")}
    def execute(command, log, cwd=root):
        child_env = env if cwd == root else {key: value for key, value in env.items()
            if key not in {"VOICELAYER_SPEECH_WIRE", "VOICELAYER_SPEECH_TIMING_WIRE"}}
        status = runner.run(["nice", "-n", "19", *command], run / log, 900, cwd=cwd, env=child_env)
        output = (run / log).read_text()
        print(output, end="", flush=True)
        return status, output
    status, _ = execute([sys.executable, "-B", "formal/speech-queue/test_speech_data_conformance.py"], "speech-data-safety.log")
    assert status == 0, "Speech data projection/scratch isolation guard failed"
    bun = ["bun", "test", "src/__tests__/tts-long-read-runtime.test.ts", "-t", "F-speech"]
    status, output = execute(bun, "speech-data-daemon.log")
    assert status == 0 and f"QueuedCountExcludesCurrent replayed {len(cases)}" in output and " 0 fail" in output
    frames = sum(sum(event["type"] == "queue" for event in row["events"])
                 for row in json.loads((run / "speech-data-wire.json").read_text()))
    status, output = execute(["swift", "test", "--package-path", "flow-bar", "--scratch-path", ".build.noindex/swift",
                              "--filter", "SpeechDataConformanceTests"], "speech-data-swift.log")
    assert status == 0 and f"Speech data replayed {len(cases)} real queue scenarios and first speaking frame" in output and f"; {frames} queue frames" in output
    fixed = (root / "src/tts.ts").read_text()
    mutants = [
        ("preparing", "QueuedCountExcludesCurrent", [('priority: this.preparing.job.priority,\n        is_current: true,',
         'priority: this.preparing.job.priority,\n        is_current: false,')]),
        ("resume", "QueuedCountExcludesCurrent", [('    this.pending.unshift(job);\n    this.processNext();\n    this.emitQueueSnapshot();\n    return true;',
         '    this.pending.unshift(job);\n    this.emitQueueSnapshot();\n    this.processNext();\n    return true;'),
         ('is_current: job.resuming === true,', 'is_current: false,')]),
        ("timing", "TimingNeverBlankWhilePlaying", [('        initial_timing: initialPlaybackTiming(next.metadata.text, durationMs ?? undefined, next.metadata.wordBoundaries, next.metadata.alignedWords),\n', '')]),
    ]
    results = []
    for name, prop, edits in mutants:
        mutated = fixed
        for before, after in edits:
            assert mutated.count(before) == 1, f"Mutant anchor drift: {name}/{prop}"
            mutated = mutated.replace(before, after)
        with mutant_copy(root, run) as scratch:
            (scratch / "src/tts.ts").write_text(mutated)
            status, output = execute([*bun[:-1], prop], f"speech-data-mutant-{name}.log", cwd=scratch)
            assert status != 0 and f"error: {prop}" in output and " 1 fail" in output, f"Surviving runtime mutant: {name}/{prop}"
            results.append(dict(name=name, property=prop, mutation=edits, expected="FAIL", actual="FAIL", exit=status))
        assert (root / "src/tts.ts").read_text() == fixed, "Tracked source changed during scratch mutant"
    (run / "speech-data-results.json").write_text(json.dumps(dict(projected_cases=len(cases),
        native_queue_frames=frames, native_first_speaking_frames=1, mutants=results), indent=2) + "\n")
    print(f"PASS: speech data {len(cases)} scenarios / {frames} real queue frames + first speaking frame; all {len(mutants)} scratch runtime mutants killed", flush=True)
