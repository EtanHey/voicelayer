#!/usr/bin/env python3
"""Run the real tests against clean code and isolated no-Qwen/no-reap mutants.

MANUAL verification tool: not invoked by bun test or CI. The hook mutant cases
are intentionally slow. On the verification host, run from the repository root:

    ~/.local/state/captain-2.2.61/heavy.sh F-flake python3 \
        tests/check_long_read_hook_mutants.py \
        --receipt-dir docs.local/F-flake-mutants --runs 5

Use a fresh receipt directory for each invocation. --test-ref
selects the original test sources for a before/after comparison. No tracked
product is edited; fixture teardown remains responsible for injected leaks.
"""

import argparse
import hashlib
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
LONG = "src/__tests__/tts-long-read-runtime.test.ts"
HOOK = "tests/hook-orphan-daemon.test.ts"
CASES = {
    "long": (LONG, "chunks the Qwen3 tier directly and supplies the same cancellable generation"),
    "hook": (HOOK, "independent hook test roots isolate fixtures and reap daemons on every exit path"),
}


def replace_once(source, before, after):
    if source.count(before) != 1:
        raise RuntimeError(f"mutation anchor must occur exactly once: {before}")
    return source.replace(before, after, 1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--receipt-dir", type=Path, required=True)
    parser.add_argument("--test-ref")
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--only", choices=CASES)
    args = parser.parse_args()
    if args.runs < 1:
        parser.error("--runs must be positive")
    receipts = args.receipt_dir.resolve()
    receipts.mkdir(parents=True, exist_ok=True)
    rows = []
    watched = [ROOT / LONG, ROOT / HOOK, ROOT / "tests/test_hook_orphan_daemon.sh",
               ROOT / "src/tts.ts", ROOT / "scripts/supervise-test-daemon.py"]
    original = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in watched}
    test_root = ROOT / ".test-tmp"
    test_root.mkdir(exist_ok=True)

    def run(checkout, label, kind, mutant):
        path, name = CASES[kind]
        log, xml = receipts / f"{label}.log", receipts / f"{label}.xml"
        if log.exists() or xml.exists():
            raise RuntimeError(f"{label}: choose a fresh receipt directory")
        command = ["bun", "test", path, "--test-name-pattern", re.escape(name) + "$",
                   "--reporter=junit", "--reporter-outfile", str(xml)]
        load, started = os.getloadavg(), time.monotonic()
        with log.open("w") as output:
            result = subprocess.run(command, cwd=checkout,
                                    env={**os.environ, "NO_COLOR": "1", "PYTHONDONTWRITEBYTECODE": "1"},
                                    stdout=output, stderr=subprocess.STDOUT)
        report = ET.parse(xml).getroot()
        names = {name}
        if kind == "long":
            names.add("long-read real runtime with owned synth/player fakes > " + name)
        cases = [c for c in report.iter("testcase") if c.attrib["name"] in names]
        if len(cases) != 1:
            raise RuntimeError(f"{label}: missing or duplicate test; see {log}")
        failure = cases[0].find("failure")
        detail = "" if failure is None else failure.attrib.get("message", "") + "\n" + "".join(failure.itertext())
        if cases[0].find("skipped") is not None or cases[0].find("error") is not None:
            raise RuntimeError(f"{label}: skipped or errored case; see {log}")
        if mutant:
            # An unrelated timeout/startup/decoding failure is never a catch.
            if kind == "long":
                assertion = 'expect(calls.join(" ")).toBe(longText)'
                locations = [i for i, line in enumerate((checkout / path).read_text().splitlines(), 1)
                             if assertion in line]
                if len(locations) != 1:
                    raise RuntimeError("Qwen assertion must occur exactly once")
                intended = (assertion in log.read_text() and f"{path}:{locations[0]}:" in detail
                            and 'Received: ""' in detail)
            else:
                intended = "FAIL success: surviving daemon/descendants:" in detail
            if (result.returncode != 1 or failure is None or failure.attrib.get("type") != "AssertionError"
                    or not intended or "hook timed out" in detail or "codec can't decode" in detail):
                raise RuntimeError(f"{label}: mutant did not fail on its intended assertion; see {log}")
        elif result.returncode != 0 or failure is not None:
            raise RuntimeError(f"{label}: clean control failed; see {log}")
        row = dict(run=label, test=kind, source_ref=args.test_ref or "HEAD", load=load,
                   elapsed_seconds=time.monotonic() - started, test_seconds=cases[0].attrib.get("time"),
                   expected="FAIL intended assertion" if mutant else "PASS",
                   actual="FAIL intended assertion" if mutant else "PASS", returncode=result.returncode)
        rows.append(row)
        (receipts / "results.json").write_text(json.dumps(rows, indent=2) + "\n")
        print(json.dumps(row), flush=True)

    with tempfile.TemporaryDirectory(prefix="flake-mut-", dir=test_root) as temp:
        checkout = Path(temp)
        for directory in ("src", "scripts", "tests"):
            shutil.copytree(ROOT / directory, checkout / directory,
                            ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
        for name in ("bunfig.toml", "package.json"):
            shutil.copy(ROOT / name, checkout)
        for name in ("node_modules", "flow-bar", "launchd"):
            (checkout / name).symlink_to(ROOT / name, target_is_directory=True)
        if args.test_ref:
            for name in (LONG, HOOK, "tests/test_hook_orphan_daemon.sh"):
                (checkout / name).write_bytes(subprocess.check_output(
                    ["git", "show", f"{args.test_ref}:{name}"], cwd=ROOT))
        for kind in ([args.only] if args.only else CASES):
            run(checkout, f"{kind}-clean", kind, False)
            product = checkout / ("src/tts.ts" if kind == "long" else "scripts/supervise-test-daemon.py")
            clean = product.read_text()
            if kind == "long":
                mutated = replace_once(clean,
                    "?? await synthesizeLongReadChunk(displayChunk, profile, signal, policy);",
                    '?? await synthesizeLongReadChunk(displayChunk, { ...profile, engine: "edge" }, signal, policy);')
            else:
                mutated = clean
                for signature in ("def stop_group(child, run_dir):", "def cleanup_group(run_dir):"):
                    mutated = replace_once(mutated, signature,
                        signature + '\n    if os.environ.get("HOOK_CASE") == "success":\n        return')
            product.write_text(mutated)
            try:
                for number in range(1, args.runs + 1):
                    run(checkout, f"{kind}-mutant-{number}", kind, True)
            finally:
                product.write_text(clean)
    if any(hashlib.sha256(Path(p).read_bytes()).hexdigest() != digest for p, digest in original.items()):
        raise RuntimeError("tracked test or product changed during mutant verification")
    print(f"PASS: {len(rows)} expected outcomes; tracked product unchanged", flush=True)


if __name__ == "__main__":
    main()
