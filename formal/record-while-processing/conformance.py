"""Real daemon admission cases and non-vacuity witnesses from exhaustive TLC states."""
import json
from pathlib import Path
import re

root = Path(__file__).resolve().parents[2]
cache = root / ".build.noindex/record-while-processing"
current = json.loads((cache / "current-states.json").read_text())
fixed = json.loads((cache / "fixed-states.json").read_text())
graph = json.loads((cache / "fixed-graph.json").read_text())


def field(label, key):
    return re.search(rf'\b{key} \|-> "([^"]+)"', label)[1]


def stage(label):
    return dict(re.findall(r'(A|B) \|-> "([^"]+)"', label))


cases = {}
for label in current:
    if field(label, "event") != "socket":
        continue
    target = field(label, "target")
    after = stage(label)
    outcome = "accept" if after[target] == "recording" else "reject"
    worker = any(value in {"transcribing", "cancelling"} for value in after.values())
    assert outcome == ("reject" if worker else "accept"), "Daemon and UI ownership were conflated"
    row = {"state": "transcribing" if worker else "idle", "outcome": outcome}
    cases[json.dumps(row, sort_keys=True)] = row
assert {row["outcome"] for row in cases.values()} == {"accept", "reject"}
(cache / "conformance.json").write_text(json.dumps(list(cases.values())))
predicates = {
    "A pastes while B records": lambda x: stage(x) == {"A": "pasted", "B": "recording"},
    "B cancelled while A still transcribes": lambda x: stage(x) == {"A": "transcribing", "B": "cancelled"},
    "cooldown ring armed for A": lambda x: field(x, "guard") == "A" and "ring |-> TRUE" in x,
    "stale A guard after A pasted while B records": lambda x: field(x, "guard") == "A" and stage(x) == {"A": "pasted", "B": "recording"},
    "timeout retains a take": lambda x: field(x, "event") == "timeout" and "saved |-> {}" not in x,
}
coverage = {name: sum(predicate(label) for label in fixed) for name, predicate in predicates.items()}
coverage["Escape cancels before cooldown completes"] = sum(
    "ring |-> TRUE" in graph["nodes"][source] and field(graph["nodes"][target], "event") == "Escape"
    and "ring |-> FALSE" in graph["nodes"][target]
    for source, target in graph["edges"])
assert all(coverage.values()), coverage
coverage.update(currentStates=len(current), fixedStates=len(fixed), daemonAdmissionCases=len(cases))
(root / "formal/record-while-processing/results/coverage.json").write_text(json.dumps(coverage, indent=2) + "\n")
print(json.dumps(coverage, indent=2))
