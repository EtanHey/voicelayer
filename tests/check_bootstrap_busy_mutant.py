#!/usr/bin/env python3
"""Require clean busy/UNKNOWN tests to pass and the missing-reset mutant to fail.

On the shared M4, invoke through captain heavy.sh with --receipt-dir pointing at
docs.local. Product and test modules are copied into ephemeral test fixtures;
tracked product code is never changed. Every mutant failure must show autostart
mutation in the empty-call-log assertion or an exit after the busy observation.
"""

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
TEST = ROOT / "src/__tests__/update-gate-bootstrap.test.ts"
PRODUCT = ROOT / "src/update-gate-bootstrap.ts"
QUEUE = "queue depth, diagnostics and direct CLI each block independently"
EXPECTED = [
    "busy legacy daemon waits, names transcription, never quits/unloads/installs",
    "process fallback busy waits even with idle daemon",
    QUEUE,
    "unreadable socket refuses unless process/diag evidence is clean AND human confirmed",
    "unreadable process inventory stays UNKNOWN despite human confirmation",
    "busy to idle resumes, installer failure retains closed gate and disabled autostart",
    *[f"R1 newest diagnostic wins across legacy and default logs: {x}" for x in ["legacy", "default"]],
    *[f"R2 stale diagnostics cannot prove idle: {x}" for x in ["no-job", "wrong-pid", "old-line", "fresh-nondiag"]],
]


def replace_once(source, before, after):
    if source.count(before) != 1:
        raise RuntimeError(f"mutation anchor must occur exactly once: {before}")
    return source.replace(before, after, 1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--receipt-dir", type=Path, required=True)
    parser.add_argument("--runs", type=int, default=3)
    args = parser.parse_args()
    if args.runs < 1:
        parser.error("--runs must be positive")
    receipts = args.receipt_dir.resolve()
    receipts.mkdir(parents=True, exist_ok=True)
    bun = shutil.which("bun")
    if not bun:
        raise RuntimeError("bun is required")
    source = TEST.read_text()
    product = PRODUCT.read_text()
    mutant = replace_once(product, 'if (!next.startsWith("idle")) since = 0;\n      else if (!since)', "if (!since)")
    mutant = re.sub(r'(from ["\'])\./([^"\']+)(["\'])',
                    lambda m: m[1] + str(PRODUCT.parent / m[2]) + m[3], mutant)
    test_root = ROOT / ".test-tmp"
    test_root.mkdir(exist_ok=True)
    rows = []

    def run(label, path, expected, must_fail):
        xml = receipts / f"{label}.xml"
        log = receipts / f"{label}.log"
        if xml.exists() or log.exists():
            raise RuntimeError(f"{label}: receipt already exists; choose a fresh --receipt-dir")
        command = [bun, "test", str(path), "--test-name-pattern", "^(?:" + "|".join(re.escape(n) for n in expected) + ")$",
                   "--reporter=junit", "--reporter-outfile", str(xml)]
        started = time.monotonic()
        load = os.getloadavg()
        result = subprocess.run(command, cwd=ROOT, env={**os.environ, "NO_COLOR": "1"},
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        log.write_text(result.stdout)
        report = ET.parse(xml).getroot()
        cases = {c.attrib["name"]: c for c in report.iter("testcase") if c.attrib["name"] in expected}
        if (set(cases) != set(expected) or result.returncode != (1 if must_fail else 0)
                or int(report.attrib.get("failures", 0)) != (len(expected) if must_fail else 0)
                or int(report.attrib.get("errors", 0)) != 0):
            raise RuntimeError(f"{label}: wrong case inventory or exit; see {receipts / (label + '.log')}")
        for name in expected:
            case = cases[name]
            failure = case.find("failure")
            if must_fail:
                detail = "" if failure is None else ET.tostring(failure, encoding="unicode")
                assertion = failure is not None and failure.attrib.get("type") == "AssertionError" and "toBe" in detail
                early_exit = "fixture exited (1) before two polls after" in detail
                if "disable " not in detail or not (assertion or early_exit):
                    raise RuntimeError(f"{label}: {name} did not catch autostart mutation after observing busy")
            elif failure is not None or case.find("error") is not None or case.find("skipped") is not None:
                raise RuntimeError(f"{label}: clean control did not pass: {name}")
            rows.append({"run": label, "test": name, "expected": "FAIL on disable" if must_fail else "PASS",
                         "actual": "FAIL on disable" if must_fail else "PASS", "test_seconds": case.attrib.get("time")})
        print(f"{label}: {len(expected)}/{len(expected)} expected outcomes; load {load}; {time.monotonic() - started:.3f} s", flush=True)
        (receipts / "mutant-results.json").write_text(json.dumps(rows, indent=2) + "\n")

    with tempfile.TemporaryDirectory(prefix="boot-mutant-", dir=test_root) as temp:
        directory = Path(temp)
        mutant_path = directory / "missing-busy-reset.ts"
        mutant_path.write_text(mutant)
        copied = replace_once(source, 'from "./setup/test-tmp"', f'from {json.dumps(str(TEST.parent / "setup/test-tmp"))}')
        clean_test = directory / "clean-bootstrap.test.ts"
        clean_test.write_text(copied)
        run("clean-control", clean_test, EXPECTED, False)
        copied = replace_once(copied, 'join(repo, "src/update-gate-bootstrap.ts")', json.dumps(str(mutant_path)))
        mutant_test = directory / "mutant-bootstrap.test.ts"
        mutant_test.write_text(copied)
        for number in range(1, args.runs + 1):
            run(f"M1-{number}", mutant_test, EXPECTED, True)
            for signal in ["diag", "direct"]:
                variant = directory / f"mutant-{signal}.test.ts"
                variant.write_text(replace_once(copied, '["queue", "diag", "direct"]', json.dumps([signal])))
                run(f"M1-{signal}-{number}", variant, [QUEUE], True)
    if PRODUCT.read_text() != product or TEST.read_text() != source:
        raise RuntimeError("tracked source changed during the guard")
    print(f"PASS: clean control and all {14 * args.runs} mutant detections; tracked product unchanged", flush=True)


if __name__ == "__main__":
    main()
