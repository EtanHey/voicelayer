#!/usr/bin/env python3
"""Bounded isolated regression gate. Pending native coverage never counts as PASS."""
import argparse
import json
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parent.parent
CASES = {
    'socket framing': ['socket-byte-framing', 'socket-partial-write'],
    'socket reconnect': ['mcp-bridge'],
    'stop and cancel': ['socket-stop-queue'],
    'queued recordings': ['recording-take-queue'],
    'history ingress': ['socket-raw-speak-archive-ingress', 'speech-history-model'],
    'update admission': ['update-gate-admission', 'recognizer-update-admission'],
    'update fail open': ['update-gate-failopen'],
    'launchd ownership': ['launchd-install', 'mcp-socket-owner'],
}
PENDING = [
    'F5 tap, hold, double tap lock, tap again lock and hint timing',
    'Option F5 pause, resume, seek and replay',
    'paste target and iTerm2, Warp, Terminal, cmux, Ghostty typing',
    'History fallback, cancel, hide and record after record',
    'Ask, Speak and Dictation history play, copy, paste, retranscribe and details',
    'History timestamps, day header, 6/8/20 rows and close gestures',
    'teleprompter, typed feedback and mic name/time wings',
    'tooltip hover on every control',
    'mic reorder, dictionary CRUD, recognizer load/unload and permission revocation',
    'installed update and restore',
    'mute and unmute within one take',
    'NarrationLayer speak, ask and read contract',
]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--report', required=True, type=Path)
    parser.add_argument('--release', action='store_true', help='fail while native coverage is pending')
    args = parser.parse_args()
    if args.report.exists():
        parser.error('report already exists')
    args.report.parent.mkdir(parents=True, exist_ok=True)
    start = time.monotonic()
    rows = []
    try:
        for flow, suites in CASES.items():
            paths = [f'src/__tests__/{suite}.test.ts' for suite in suites]
            remaining = 900 - (time.monotonic() - start)
            if remaining <= 0:
                raise subprocess.TimeoutExpired('e2e deadline', 900)
            result = subprocess.run(['bun', 'test', *paths], cwd=ROOT, timeout=remaining)
            rows.append(dict(flow=flow, cases=paths, status='PASS' if result.returncode == 0 else 'FAIL'))
    except subprocess.TimeoutExpired:
        rows.append(dict(flow='15 minute deadline', status='FAIL'))
    rows.extend(dict(flow=flow, status='M1-pending') for flow in PENDING)
    failed = any(row['status'] == 'FAIL' for row in rows)
    report = dict(seconds=round(time.monotonic()-start, 2), rows=rows,
                  releaseReady=False, isolatedPassed=not failed)
    args.report.write_text(json.dumps(report, indent=2)+'\n')
    return 1 if failed or args.release else 0

if __name__ == '__main__':
    raise SystemExit(main())
