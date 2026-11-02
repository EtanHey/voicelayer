"""Lane F expectations and exact-property negative controls (no product execution)."""
import json
import re

# name: (property, single semantic knob removed)
MUTANTS = {
    "F5PauseTypeBound": ("TypeOK", "Fault=TypeBound: relax NewSpeech admission bound by one"),
    "F5PauseOpenFirst": ("NoSpeechDuringOpenMic", "PauseBeforeOpen=FALSE: open before pause"),
    "F5PauseIgnoreF5": ("F5PausesPlayingSpeech", "Fault=IgnoreF5: bypass playing-speech F5 admission"),
    "F5PauseManualResume": ("ManualPausePersists", "Fault=ManualResume: admit user owner to auto-resume"),
    "F5PauseResumeOnPaste": ("NoF5PauseOutsideCapture", "ResumeOnEveryEnd=FALSE: resume only pasted outcome"),
    "F5PauseResumePosition": ("ResumeFromPausedPosition", "Fault=ResumePosition: restart at zero"),
    "F5PauseDoubleResume": ("NoDoubleResume", "Fault=DoubleResume: remove stale-settlement idempotency"),
    "F5PauseStopResumes": ("StopWins", "Fault=StopResumes: admit stopped capture to auto-resume"),
    "F5PauseKeepOwner": ("OwnerConsistent", "Fault=KeepOwner: omit owner clear on auto-resume"),
    "F5PauseReleaseDrops": ("ReleaseNeverDropsRead", "Fault=ReleaseDrops: release calls speech stop"),
    "F5PauseWordBoundary": ("PauseAtWordBoundary", "Fault=WordBoundary: omit snap to word start"),
    "F5PauseQueueCount": ("QueuedCountExcludesCurrent", "Fault=QueueCount: count preparing current as waiting"),
    "F5PauseTimingBlank": ("TimingNeverBlankWhilePlaying", "Fault=TimingBlank: omit initial timing estimate"),
    "F5PauseStuck": ("AutoPauseNeverStuck", "ResumeOnEveryEnd=FALSE: resume only pasted outcome"),
}
CURRENT = {
    "F5PauseCurrent": "F5PausesPlayingSpeech",
    "F5PauseCurrentRelease": "ReleaseNeverDropsRead",
    "F5PauseCurrentWordBoundary": "PauseAtWordBoundary",
    "F5PauseCurrentQueued": "QueuedCountExcludesCurrent",
    "F5PauseCurrentTiming": "TimingNeverBlankWhilePlaying",
}
EXPECTED = {**CURRENT, **{name: row[0] for name, row in MUTANTS.items()}, "F5PauseFixed": None}
TEMPORAL = {"AutoPauseNeverStuck"}


def declared_properties(config):
    return re.findall(r"^\s*(?:INVARIANTS?|PROPERT(?:Y|IES))\s+(.+)$", config, re.M)


def check_mutant_coverage(directory):
    baseline = (directory / "F5PauseFixed.cfg").read_text()
    properties = set(" ".join(declared_properties(baseline)).split())
    assert properties == {row[0] for row in MUTANTS.values()}, "Every fixed property needs its own mutant"
    constants = lambda text: dict(re.findall(r'(\w+)\s*=\s*("[^"\n]*"|TRUE|FALSE|\d+)', text))
    fixed_constants = constants(baseline)
    for name, (prop, _) in MUTANTS.items():
        config = (directory / f"{name}.cfg").read_text()
        assert declared_properties(config) == [prop], f"{name} must isolate {prop}"
        mutant_constants = constants(config)
        assert mutant_constants.keys() == fixed_constants.keys(), f"{name}: changed constant set"
        changes = [key for key in fixed_constants if mutant_constants[key] != fixed_constants[key]]
        assert len(changes) == 1, f"{name} must flip exactly one knob: {changes}"
        assert changes[0] in {"Fault", "PauseBeforeOpen", "ResumeOnEveryEnd"}, name


def valid_result(status, output, expected, config):
    violations = re.findall(r"Invariant (\w+) is violated", output)
    if expected in TEMPORAL:
        # TLC 2.19's temporal headline is anonymous. Do not accept that headline
        # alone: isolate the named property and inspect its named diagnostic discharge
        # predicate in the actual lasso. Every state in the cycle must owe resume.
        if not (status == 13 and not violations and declared_properties(config) == [expected]
                and "Temporal properties were violated" in output):
            return False
        states = re.findall(r"State (\d+):[^\n]*\n(.*?)(?=\nState \d+:|\nBack to state |\nStuttering|\nFinished checking|\Z)", output, re.S)
        loop = re.search(r"Back to state (\d+):", output)
        if loop:
            cycle = [body for index, body in states if int(index) >= int(loop[1])]
        elif "Stuttering" in output:
            cycle = [states[-1][1]] if states else []
        else:
            return False
        return bool(cycle) and all(re.search(rf"{expected} \|-> FALSE", body) and re.search(r'/\\ owner = "f5"', body) for body in cycle)
    if expected:
        return status == 12 and violations == [expected]
    return (status == 0 and not violations and "Temporal properties were violated" not in output
            and "Model checking completed. No error has been found." in output)


def check_reachability(run):
    labels = []
    for line in (run / "F5PauseFixed.dot").read_text().splitlines():
        node = re.match(r'(-?\d+) \[label="((?:\\.|[^"\\])*)"', line)
        if node:
            labels.append(json.loads('"' + node[2] + '"'))
    output = (run / "F5PauseFixed.log").read_text()
    assert len(labels) == int(re.findall(r"(\d+) distinct states found", output)[-1]), "Incomplete F5 graph"
    events = {re.search(r'event = "(\w+)"', label)[1] for label in labels}
    required = {"stop_in_capture", "queue_speech", "f5_busy", "stale_capture_end", "user_pause_converts"}
    required |= {"end_" + outcome + suffix for outcome in ("pasted", "empty", "failed", "cancelled", "timeout")
                 for suffix in ("", "_auto_resume")}
    assert required <= events, f"Unreached contract events: {required - events}"
    for held in ("no", "hold", "locked"):
        assert any('event = "f5_auto_pause_then_open"' in label and f'held = "{held}"' in label for label in labels)
    for capture in ("recording", "transcribing"):
        assert any('event = "hold_release"' in label and f'capture = "{capture}"' in label
                   and 'speech = "paused"' in label for label in labels), "Release/lock path unreachable"
    assert any('event = "queue_speech"' in label and 'capture = "transcribing"' in label for label in labels)
    assert any('event = "end_pasted_auto_resume"' in label and re.search(r"\bpos = 2\n", label)
               and re.search(r"\bpausedAt = 1\n", label) for label in labels), "Nonzero word resume unreachable"
    print(f"F5PauseFixed: {len(labels)} states; all outcomes, gestures, lock/release, queue-during-capture and nonzero resume reachable", flush=True)


def render_receipt(rows):
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
    lines += ["", "TLC log excerpts (emitted by the checker, never transcribed):", "", "```text"]
    for row in rows:
        lines.append(row["name"] + ":")
        lines.extend(row["excerpt"])
    return "\n".join(lines + ["```", ""])
