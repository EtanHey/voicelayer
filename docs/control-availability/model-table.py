#!/usr/bin/env python3
"""Dump the formal model's availability table with TLC and pin its SHA-256.

The Swift oracle (ControlAvailabilityModelOracle) must reproduce exactly this table over the model's own
`Seeds`; ControlAvailabilityModelTableTests compares its hash with model-table.json. Run:
    python3 -B docs/control-availability/model-table.py            # check (exit 1 on drift)
    python3 -B docs/control-availability/model-table.py --write    # re-record
    python3 -B docs/control-availability/model-table.py --dump F   # also write the canonical table to F
Needs Java (PATH or /opt/homebrew/opt/openjdk/bin). Never an installed-app verdict.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
MODEL = HERE / "model" / "ControlAvailability.tla"
MANIFEST = HERE / "model-table.json"
MODEL_COMMIT = "4bf20052"
MODEL_BLOB = "7d00d4ec5587665ad152c647d571c023d9555f3e"
TABLE_MODULE = """---- MODULE ControlAvailabilityTable ----
EXTENDS ControlAvailability, TLC
Row(x) == <<x, [c \\in Controls |-> <<Visible(c,x), UIReason(c,x), Handler(c,x)>>],
            <<SelectionCanRead(x), SelectionReason(x)>>>>
ASSUME \\A x \\in Seeds : PrintT(Row(x))
TInit == s = 0 /\\ FALSE
====
"""
TABLE_CFG = 'CONSTANTS Policy = "Fixed" Scenario = "all"\nINIT TInit\nNEXT Next\nCHECK_DEADLOCK FALSE\n'


def parse_values(text):
    """Parse the sequence of TLA+ values TLC printed (records, functions, tuples, strings, booleans, ints)."""
    i, n = 0, len(text)

    def ws():
        nonlocal i
        while i < n and text[i] in " \t\r\n":
            i += 1

    def ident():
        nonlocal i
        start = i
        while i < n and (text[i].isalnum() or text[i] == "_"):
            i += 1
        return text[start:i]

    def value():
        nonlocal i
        ws()
        if text.startswith("<<", i):
            i += 2
            items = []
            ws()
            while not text.startswith(">>", i):
                items.append(value())
                ws()
                if text[i] == ",":
                    i += 1
                ws()
            i += 2
            return tuple(items)
        if text[i] == "[":
            i += 1
            record = {}
            while True:
                ws()
                key = ident()
                ws()
                assert text.startswith("|->", i), text[i:i + 40]
                i += 3
                record[key] = value()
                ws()
                if text[i] == "]":
                    i += 1
                    return record
                assert text[i] == ",", text[i:i + 40]
                i += 1
        if text[i] == '"':
            end = text.index('"', i + 1)
            s = text[i + 1:end]
            i = end + 1
            return s
        word = ident()
        if word in ("TRUE", "FALSE"):
            return word == "TRUE"
        return int(word)

    values = []
    ws()
    while i < n:
        values.append(value())
        ws()
    return values


def literal(v):
    return ("TRUE" if v else "FALSE") if isinstance(v, bool) else str(v)


def canonical_lines(rows):
    lines = []
    for state, controls, selection in rows:
        key = ",".join(f"{k}={literal(state[k])}" for k in sorted(state))
        for control, (visible, reason, handler) in controls.items():
            lines.append(f"{key}|{control}|{int(visible)}|{int(handler)}|{reason}")
        lines.append(f"{key}|#Selection|{int(selection[0])}|-|{selection[1]}")
    return sorted(lines)


def run_tlc():
    work = ROOT / ".build.noindex" / "control-availability-table"
    work.mkdir(parents=True, exist_ok=True)
    (work / "ControlAvailability.tla").write_text(MODEL.read_text())
    (work / "ControlAvailabilityTable.tla").write_text(TABLE_MODULE)
    (work / "ControlAvailabilityTable.cfg").write_text(TABLE_CFG)
    env = dict(os.environ)
    env["PATH"] = "/opt/homebrew/opt/openjdk/bin:" + env.get("PATH", "")
    out = subprocess.run(["bash", str(ROOT / "formal" / "tlc.sh"), "-workers", "1", "-metadir", str(work / "meta"),
                          "ControlAvailabilityTable.tla"], cwd=work, env=env, capture_output=True, text=True)
    marker = out.stdout.find("Starting...")
    end = out.stdout.find("Computing initial states...")
    if out.returncode != 0 or marker < 0 or end < 0:
        raise SystemExit("TLC failed:\n" + out.stdout[-2000:] + out.stderr[-2000:])
    body = out.stdout[out.stdout.index("\n", marker) + 1:end]
    return parse_values(body)


def generate():
    blob = subprocess.check_output(["git", "hash-object", str(MODEL)], cwd=ROOT).decode().strip()
    assert blob == MODEL_BLOB, f"vendored model drifted from {MODEL_COMMIT}: {blob}"
    rows = run_tlc()
    lines = canonical_lines(rows)
    text = "\n".join(lines) + "\n"
    reasons = sorted({line.rsplit("|", 1)[1] for line in lines} - {""})
    return text, {
        "model": "docs/control-availability/model/ControlAvailability.tla",
        "modelCommit": MODEL_COMMIT, "modelBlob": MODEL_BLOB, "policy": "Fixed",
        "seeds": len(rows), "lines": len(lines),
        "format": "seedKey|control|visible|handler|UIReason, sorted bytewise; '#Selection' rows are "
                  "SelectionCanRead|-|SelectionReason; seedKey = sorted field=value pairs",
        "tableSha256": hashlib.sha256(text.encode()).hexdigest(),
        "reasons": reasons,
    }


if __name__ == "__main__":
    table, manifest = generate()
    if "--dump" in sys.argv:
        Path(sys.argv[sys.argv.index("--dump") + 1]).write_text(table)
    if "--write" in sys.argv:
        MANIFEST.write_text(json.dumps(manifest, indent=2) + "\n")
    elif json.loads(MANIFEST.read_text()) != manifest:
        raise SystemExit("model-table.json is stale; re-record with --write")
    print(f"model table: {manifest['seeds']} seeds, {manifest['lines']} lines, sha256 {manifest['tableSha256']}")
