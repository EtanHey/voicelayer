import json,re
from pathlib import Path
root=Path(__file__).resolve().parents[2]
cache=root/".build.noindex/record-while-processing-runtime"
def field(label, key):
    return re.search(rf'\b{key} \|-> "([^"]+)"', label)[1]


def stage(label):
    return dict(re.findall(r'(A|B) \|-> "([^"]+)"', label))


cases={0: {"state":"idle","outcome":"accept"}, 1: {"state":"transcribing","outcome":"accept"}}
runtime = json.loads((root / ".build.noindex/record-while-processing-runtime/fixed-graph.json").read_text())
cancels = {}
drain_admissions = {}
queued_cancels = {}
for source, target in runtime["edges"]:
    before, after = runtime["nodes"][source], runtime["nodes"][target]
    origin = field(after, "event")
    before_stages, after_stages = stage(before), stage(after)
    target_take = field(after, "target")
    if origin == "drain-press" and before_stages.get(target_take) == "fresh" and after_stages.get(target_take) == "waiting":
        row = {"target": target_take, "stages": before_stages}
        drain_admissions[json.dumps(row, sort_keys=True)] = row
    if origin not in {"Escape", "click"}:
        continue
    target_take = field(after, "target")
    if before_stages.get(target_take) == "waiting" and after_stages.get(target_take) == "cancelled":
        row = {"origin": origin, "target": target_take, "stages": before_stages,
               "captureReleased": bool(re.search(r"captureReleased \|-> TRUE", before))}
        queued_cancels[json.dumps(row, sort_keys=True)] = row
    # Waiting is a local UI intent, including the atomic dispatch/open gap. Replay it separately
    # with the real F5 sequence, rather than seeding a fictional daemon-owned waiting job.
    if "waiting" in before_stages.values():
        continue
    # DOT includes state-preserving/self edges: a retained event label is not another cancellation.
    if before_stages[target_take] not in {"recording", "draining", "captured", "processing"} or after_stages[target_take] != "cancelled":
        continue
    row = {"origin": origin, "target": target_take, "stages": before_stages}
    cancels[json.dumps(row, sort_keys=True)] = row
assert any(row["stages"]["B"] == "captured" for row in cancels.values())
assert any(row["stages"]["B"] == "processing" for row in cancels.values())
assert drain_admissions and queued_cancels
corpus = dict(admissions=list(cases.values()),
    drainAdmissions=sorted(drain_admissions.values(), key=lambda row: json.dumps(row, sort_keys=True)),
    queuedCancellations=sorted(queued_cancels.values(), key=lambda row: json.dumps(row, sort_keys=True)),
    cancellations=sorted(cancels.values(), key=lambda row: json.dumps(row, sort_keys=True)))
(cache / "conformance.json").write_text(json.dumps(corpus))
(root / "formal/record-while-processing-runtime/corpus.json").write_text(json.dumps(corpus, indent=2) + "\n")
