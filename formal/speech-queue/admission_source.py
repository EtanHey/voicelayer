import json
import os
import re
from pathlib import Path


def check_admission(run, runner):
    cases = []
    for line in (run / "QueueAdmissionFixed.dot").read_text().splitlines():
        node = re.match(r'(-?\d+) \[label="((?:\\.|[^"\\])*)"', line)
        if not node:
            continue
        label = json.loads('"' + node[2] + '"')
        if not re.search(r"\bsteps = 2(?:\n|$)", label):
            continue
        cases.append(dict(playing=int(re.search(r"\bbeforePlaying = (\d+)", label)[1]),
                          pending=[int(n) for n in re.findall(r"\d+", re.search(r"\bbeforePending = <<(.*?)>>", label)[1])],
                          suspended="wasSuspended = TRUE" in label,
                          selected=int(re.search(r"\bselected = (\d+)", label)[1]),
                          event=re.search(r'\bevent = "(\w+)"', label)[1],
                          decision=re.search(r'\bdecision = "(\w+)"', label)[1]))
    assert cases and {row["event"] for row in cases} == {"selection", "stop", "f5"}
    assert {row["decision"] for row in cases} == {"stop", "read_next", "hint", "speak_text"}
    assert any(len(row["pending"]) == 2 and row["selected"] not in [row["playing"], *row["pending"]] for row in cases)
    path = run / "admission.json"
    path.write_text(json.dumps(cases))
    status = runner.run(["timeout", "-s", "KILL", "900", "swift", "test", "--package-path", "flow-bar",
                         "--scratch-path", ".build.noindex/swift", "--filter", "ReadQueueTests.testModelAdmissionCasesDriveRealVoiceState|SocketServerTests.testQueueAdmissionSocketBoundary"],
                        run / "swift-admission.log", 900, cwd=Path(__file__).resolve().parents[2],
                        env={**os.environ, "VOICELAYER_ADMISSION_CASES": str(path), "VOICELAYER_ADMISSION_WIRE": str(run / "wire.ndjson")})
    output = (run / "swift-admission.log").read_text()
    print(output, flush=True)
    assert status == 0 and f"Replayed {len(cases) * 4} TLC cases" in output, "Real Swift admission diverged"
    status = runner.run(["timeout", "-s", "KILL", "900", "bun", "test", "src/__tests__/selection-admission.test.ts"],
                        run / "wire-conformance.log", 900, cwd=Path(__file__).resolve().parents[2],
                        env={**os.environ, "VOICELAYER_ADMISSION_WIRE": str(run / "wire.ndjson")})
    print((run / "wire-conformance.log").read_text(), flush=True)
    assert status == 0, "Swift socket commands diverged at daemon boundary"
