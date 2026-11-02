"""Lane F expectations and exact-property negative controls (no product execution)."""
import json
import os
import sys
import re

# name: (property, single semantic knob removed)
MUTANTS = {
    "F5PauseInvalidOwner": ("TypeOK", "Fault=InvalidOwner: corrupt pause-owner domain"),
    "F5PauseOpenFirst": ("NoSpeechDuringOpenMic", "PauseBeforeOpen=FALSE: open before pause"),
    "F5PauseIgnoreF5": ("F5PausesPlayingSpeech", "Fault=IgnoreF5: bypass playing-speech F5 admission"),
    "F5PauseManualResume": ("ManualPausePersists", "Fault=ManualResume: admit user owner to auto-resume"),
    "F5PauseResumeOnPaste": ("NoF5PauseOutsideCapture", "ResumeOnEveryEnd=FALSE: resume only pasted outcome"),
    "F5PauseResumePosition": ("ResumeFromPausedPosition", "Fault=ResumePosition: restart at zero"),
    "F5PauseDoubleResume": ("NoDoubleResume", "Fault=DoubleResume: stale settlement actually resumes/repositions the read"),
    "F5PauseStopResumes": ("StopWins", "Fault=StopResumes: admit stopped capture to auto-resume"),
    "F5PauseKeepOwner": ("OwnerConsistent", "Fault=KeepOwner: UserPlay retains user owner (isolating)"),
    "F5PauseReleaseDrops": ("ReleaseNeverDropsRead", "Fault=ReleaseDrops: release calls speech stop"),
    "F5PauseWordBoundary": ("PauseAtWordBoundary", "Fault=WordBoundary: omit snap to word start"),
    "F5PauseQueueCount": ("QueuedCountExcludesCurrent", "Fault=QueueCount: count preparing current as waiting"),
    "F5PauseTimingBlank": ("TimingNeverBlankWhilePlaying", "Fault=TimingBlank: omit initial timing estimate"),
    "F5PauseStuck": ("AutoPauseNeverStuck", "Fault=NoFairness: drop only clock fairness; all safety guards intact"),
    "F5PausePostRelease": ("ReleaseNeverDropsRead", "Fault=PostRelease: settled capture key-up calls speech Stop"),
    "F5PauseStaleResumesPaused": ("NoDoubleResume", "Fault=StaleResumesPaused: reviewer real-resume probe"),
    "F5PauseParkZero": ("PauseAtWordBoundary", "Fault=ParkZero: park and later resume word zero"),
    "F5PauseParkNextWord": ("PauseAtWordBoundary", "Fault=ParkNextWord: skip to the next word"),
    "F5PauseStartDuringCapture": ("NoSpeechDuringOpenMic", "Fault=StartDuringCapture: remove StartPlayback capture guard"),
    "F5PauseIgnorePreparing": ("F5HoldsPreparingRead", "Fault=IgnorePreparing: keep current preparing-read router"),
    "F5PauseCancelPrevious": ("F5DuringTranscriptionStartsCapture", "Fault=CancelPrevious: cancel A instead of opening capture B"),
    "F5PauseResumeEarly": ("NoSpeechDuringOpenMic", "Fault=ResumeEarly: resume before every capture settles"),
    "F5PauseN6DropsRead": ("F5DuringTranscriptionStartsCapture", "Fault=N6DropsRead: open B but silently drop the parked read"),
    "F5PauseDropAtEnd": ("ResumeFromPausedPosition", "Fault=DropAtEnd: final capture settlement drops the read"),
}
CURRENT = {
    "F5PauseCurrent": "F5PausesPlayingSpeech",
    "F5PauseCurrentRelease": "ReleaseNeverDropsRead",
    "F5PauseCurrentWordBoundary": "PauseAtWordBoundary",
    "F5PauseCurrentQueued": "QueuedCountExcludesCurrent",
    "F5PauseCurrentTiming": "TimingNeverBlankWhilePlaying",
    "F5PauseCurrentPreparing": "F5HoldsPreparingRead",
    "F5PauseCurrentTranscribing": "F5DuringTranscriptionStartsCapture",
    "F5PauseCurrentPostRelease": "ReleaseNeverDropsRead",
    "F5PauseCurrentCancelPostRelease": "ReleaseNeverDropsRead",
}
EXPECTED = {**CURRENT, **{name: row[0] for name, row in MUTANTS.items()}, "F5PauseFixed": None, "F5PauseFixedTranscribing": None}
TEMPORAL = {"AutoPauseNeverStuck"}


def declared_properties(config):
    return re.findall(r"^\s*(?:INVARIANTS?|PROPERT(?:Y|IES))\s+(.+)$", config, re.M)


def check_mutant_coverage(directory):
    baseline = (directory / "F5PauseFixed.cfg").read_text()
    properties = set(" ".join(declared_properties(baseline)).split())
    assert properties == {row[0] for row in MUTANTS.values()}, "Every fixed property needs its own mutant"
    constants = lambda text: dict(re.findall(r'(\w+)\s*=\s*("[^"\n]*"|TRUE|FALSE|\d+)', text))
    fixed_constants = constants(baseline)
    diagnostic_pairs = re.findall(
        r'\(?(\w+) \\/ PrintT\("CrossKill:(\w+)"\)', (directory / "F5Pause.tla").read_text())
    assert all(left == right for left, right in diagnostic_pairs)
    assert {left for left, _ in diagnostic_pairs} == properties - TEMPORAL, "Every safety predicate needs an actual TLC diagnostic"
    for name, (prop, _) in MUTANTS.items():
        config = (directory / f"{name}.cfg").read_text()
        assert declared_properties(config) == [prop], f"{name} must isolate {prop}"
        mutant_constants = constants(config)
        assert mutant_constants.keys() == fixed_constants.keys(), f"{name}: changed constant set"
        changes = [key for key in fixed_constants if mutant_constants[key] != fixed_constants[key]]
        assert len(changes) == 1, f"{name} must flip exactly one knob: {changes}"
        assert changes[0] in {"Fault", "PauseBeforeOpen", "ResumeOnEveryEnd"}, name


def temporal_failure(output):
    return bool(re.search(r"^Error: Temporal (?:properties were violated|property \w+ was violated)\.", output, re.M))


def temporal_killed(output, expected="AutoPauseNeverStuck"):
    named = re.findall(r"^Error: Temporal property (\w+) was violated\.", output, re.M)
    if not temporal_failure(output) or (named and set(named) != {expected}):
        return False
    trace = re.findall(r"State (\d+):([^\n]*)\n(.*?)(?=\nState \d+:|\nBack to state |\nStuttering|\nFinished checking|\Z)", output, re.S)
    states = [(index, body) for index, header, body in trace if "Stuttering" not in header]
    loop = re.search(r"^(?:State \d+: )?Back to state (\d+):", output, re.M)
    if loop and any(index == loop[1] for index, _ in states):
        cycle = [body for index, body in states if int(index) >= int(loop[1])]
    elif states and re.search(rf"^State {int(states[-1][0]) + 1}: Stuttering\s*$", output, re.M):
        cycle = [states[-1][1]]
    else:
        return False
    # Legacy plural errors must still identify the property in the model's named
    # discharge record. A bare anonymous failure never supplies this evidence.
    false_goal = lambda body: bool(re.search(rf"\bobligations\s*=\s*\[\s*{re.escape(expected)}\s*\|->\s*FALSE\s*\]", body))
    # The stronger leads-to property can also be violated after an incorrect owner
    # clear. Check an actual f5 antecedent with no subsequent discharge, not a label.
    return bool(cycle) and all(map(false_goal, cycle)) and any(
        re.search(r'owner \|-> "f5"', body) and all(false_goal(later) for _, later in states[offset:])
        for offset, (_, body) in enumerate(states))


def valid_result(status, output, expected, config):
    violations = re.findall(r"Invariant (\w+) is violated", output)
    if expected in TEMPORAL:
        return (status == 13 and not violations and declared_properties(config) == [expected]
                and temporal_killed(output, expected))
    if expected:
        return status == 12 and violations == [expected]
    return (status == 0 and not violations and not temporal_failure(output)
            and "Model checking completed. No error has been found." in output)


def check_temporal_controls():
    expected = "AutoPauseNeverStuck"
    config = f"PROPERTIES {expected}\n"
    plural = ('Error: Temporal properties were violated.\nState 1: <Initial predicate>\n'
              '/\\ s = [owner |-> "f5"]\n/\\ obligations = [AutoPauseNeverStuck |-> FALSE]\n'
              '\nState 2: Stuttering\n')
    named = plural.replace("Temporal properties were violated", f"Temporal property {expected} was violated")
    for output in (plural, named):
        assert valid_result(13, output, expected, config), "Rejects a genuine named liveness failure"
        assert valid_result(13, output.replace("State 2: Stuttering", "Back to state 1: <Next>"), expected, config)
        for bad in (output.replace(expected, "WrongProperty"),
                    output.replace(f"{expected} |->", f"Wrong{expected} |->"),
                    output.replace(f"{expected} |-> FALSE", f"{expected} |-> TRUE"),
                    output.replace('owner |-> "f5"', 'owner |-> "none"'),
                    output.replace("State 2: Stuttering", ""),
                    output.replace("State 2: Stuttering", "Back to state 99: <Next>")):
            assert not valid_result(13, bad, expected, config), "Accepted an invalid temporal verdict"
    assert not valid_result(13, named.replace(f"property {expected}", "property WrongProperty"), expected, config)
    anonymous = plural.replace(f"{expected} |-> FALSE", "unidentified |-> FALSE")
    assert not valid_result(13, anonymous, expected, config), "Accepted an anonymous liveness failure"
    print("PASS: temporal verdict controls: both formats, named property and real lasso; wrong/anonymous rejected", flush=True)


def check_reachability(run):
    labels = []
    for line in (run / "F5PauseFixed.dot").open():
        node = re.match(r'(-?\d+) \[label="((?:\\.|[^"\\])*)"', line)
        if node:
            labels.append(json.loads('"' + node[2] + '"'))
    output = (run / "F5PauseFixed.log").read_text()
    assert len(labels) == int(re.findall(r"(\d+) distinct states found", output)[-1]), "Incomplete F5 graph"
    def has(label, key, value):
        return bool(re.search(rf'\b{key} \|-> {re.escape(value)}(?=,|\]|\s|$)', label))
    def witness(**fields):
        return any(all(has(label, key, value) for key, value in fields.items()) for label in labels)
    for outcome in ("pasted", "empty", "failed", "cancelled", "timeout"):
        assert witness(event='"end_' + outcome + '_auto_resume"'), outcome
    for held in ("no", "hold", "locked"):
        assert witness(event='"f5_pause"', held='"'+held+'"'), held
    assert witness(event='"f5_pause"', speech='"parked_preparing"', owner='"f5"')
    assert witness(event='"queue_speech"', queued='2', started='3'), "Third request/+2 not explored"
    assert witness(event='"end_pasted_auto_resume"', pos='2', pausedAt='1'), "Nonzero word resume unreachable"
    assert any('transcribingBefore = {1}' in label and has(label, 'issued', '2')
               and has(label, 'event', '"f5_capture"') for label in labels), "N6 capture B unreachable"
    for outcome in ("failed", "cancelled", "timeout"):
        assert witness(event='"hold_release"', lastOutcome='"'+outcome+'"', speech='"playing"'), "Late key-up " + outcome
    assert witness(event='"stale_capture_end"', owner='"user"'), "Manual pause stale-settlement case unreachable"
    print(f"F5PauseFixed: {len(labels)} states; preparing park, two overlapping captures, late key-up, stale user pause, +2 queue and word-1 resume reachable", flush=True)


def cross_kill(run, runner, command, directory):
    baseline = (directory / "F5PauseFixed.cfg").read_text()
    properties = " ".join(declared_properties(baseline)).split()
    rows = []
    module = run / "F5Pause.tla"
    module.write_bytes((directory / "F5Pause.tla").read_bytes())
    for name, (target, _) in MUTANTS.items():
        original = (directory / f"{name}.cfg").read_text()
        config = run / f"Cross{name}.cfg"
        config.write_text(original.split("INVARIANTS", 1)[0].split("PROPERTIES", 1)[0]
                          + baseline[baseline.index("INVARIANTS"):] + "CONSTRAINT CrossDiagnostics\n")
        log = run / f"{name}-all.log"
        status = runner.run([sys.executable, "-B", str(directory / "cross_tlc.py"), *command,
                             "-continue", "-lncheck", "final", "-metadir", str(run / f"cross-meta-{name}"),
                             "-config", str(config), str(module)], log, 90,
                            cwd=directory.parents[1], env=os.environ)
        output = log.read_text()
        killed = set(re.findall(r"Invariant (\w+) is violated", output))
        killed |= set(re.findall(r"CrossKill:(\w+)", output))
        if temporal_failure(output):
            assert temporal_killed(output), f"Unidentified temporal cross-kill: {name}"
            killed.add("AutoPauseNeverStuck")
        assert status in {0, 13} and target in killed and killed <= set(properties), f"Cross-kill failed: {name}\n{output}"
        assert status == 13 or "Model checking completed. No error has been found." in output, output
        if name == "F5PauseKeepOwner":
            assert killed == {"OwnerConsistent"}, f"OwnerConsistent mutant not isolating: {killed}"
        if name == "F5PauseStuck":
            assert killed == {"AutoPauseNeverStuck"}, f"Liveness mutant has collateral safety failures: {killed}"
        counts = re.search(r"(\d+) states generated, (\d+) distinct states found", output)
        assert counts, output
        rows.append(dict(name=name, killed=sorted(killed), generated=int(counts[1]), distinct=int(counts[2])))
        (run / "cross-progress.json").write_text(json.dumps(dict(properties=properties, rows=rows), indent=2) + "\n")
        print(f"{name} ALL Fixed properties: {', '.join(sorted(killed))}; {counts[0]}", flush=True)
    return dict(properties=properties, rows=rows)


def render_receipt(rows, cross=None):
    """Only measured TLC values enter these generated Markdown tables."""
    lines = ["| Config | Expected | Actual | Generated | Distinct | Depth |",
             "|---|---|---|---:|---:|---:|"]
    for row in rows:
        expected = "FAIL " + row["expected"] if row["expected"] else "PASS"
        lines.append(f'| `{row["name"]}` | {expected} | {row["actual"]} | {row["generated"]} | {row["distinct"]} | {row["depth"]} |')
    lines += ["", "| Property | Mutant config | Knob or guard removed | Expected | Actual | Generated / distinct / depth |",
              "|---|---|---|---|---|---|"]
    indexed = {row["name"]: row for row in rows}
    for name, (prop, knob) in MUTANTS.items():
        row = indexed[name]
        lines.append(f'| `{prop}` | `{name}.cfg` | {knob} | FAIL {prop} | {row["actual"]} | {row["generated"]} / {row["distinct"]} / {row["depth"]} |')
    if cross:
        properties = cross["properties"]
        lines += ["", "Cross-kill matrix: X = named TLC violation, . = survived in that complete run.", "",
                  "| Mutant | " + " | ".join(f"P{i+1}" for i in range(len(properties))) + " | Generated / distinct |",
                  "|---|" + "---|" * len(properties) + "---|"]
        for row in cross["rows"]:
            cells = ["X" if prop in row["killed"] else "." for prop in properties]
            lines.append("| " + row["name"] + " | " + " | ".join(cells)
                         + f' | {row["generated"]} / {row["distinct"]} |')
        lines += ["", *[f"- P{i+1}: `{prop}`" for i, prop in enumerate(properties)]]
    lines += ["", "TLC log excerpts (emitted by the checker, never transcribed):", "", "```text"]
    for row in rows:
        lines.append(row["name"] + ":")
        lines.extend(row["excerpt"])
    return "\n".join(lines + ["```", ""])
