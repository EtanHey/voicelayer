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
for label in fixed:
    if field(label, "event") != "socket":
        continue
    target = field(label, "target")
    after = stage(label)
    assert after[target] == "recording", "Fixed admission must start its target"
    worker = any(value in {"transcribing", "cancelling"} for value in after.values())
    row = {"state": "transcribing" if worker else "idle", "outcome": "accept"}
    cases[json.dumps(row, sort_keys=True)] = row
assert {row["state"] for row in cases.values()} == {"idle", "transcribing"}
runtime = json.loads((root / ".build.noindex/record-while-processing-runtime/fixed-graph.json").read_text())
cancels = {}
for source, target in runtime["edges"]:
    before, after = runtime["nodes"][source], runtime["nodes"][target]
    origin = field(after, "event")
    if origin not in {"Escape", "click"}:
        continue
    target_take = field(after, "target")
    before_stages, after_stages = stage(before), stage(after)
    # DOT includes state-preserving/self edges: a retained event label is not another cancellation.
    if before_stages[target_take] not in {"recording", "draining", "captured", "processing"} or after_stages[target_take] != "cancelled":
        continue
    row = {"origin": origin, "target": target_take, "stages": before_stages}
    cancels[json.dumps(row, sort_keys=True)] = row
assert any(row["stages"]["B"] == "captured" for row in cancels.values())
assert any(row["stages"]["B"] == "processing" for row in cancels.values())
corpus = dict(admissions=list(cases.values()), cancellations=sorted(cancels.values(), key=lambda row: json.dumps(row, sort_keys=True)))
(cache / "conformance.json").write_text(json.dumps(corpus))
(root / "formal/record-while-processing/corpus.json").write_text(json.dumps(corpus, indent=2) + "\n")
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
coverage.update(currentStates=len(current), fixedStates=len(fixed), daemonAdmissionCases=len(cases), nativeCancellationCases=len(cancels))
(root / "formal/record-while-processing/results/coverage.json").write_text(json.dumps(coverage, indent=2) + "\n")
print(json.dumps(coverage, indent=2))
