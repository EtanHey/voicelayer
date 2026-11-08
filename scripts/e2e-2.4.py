#!/usr/bin/env python3
"""Bounded isolated regression gate. Pending native coverage never counts as PASS."""
import argparse
import json
import re
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parent.parent
CASES = {
    'socket client driver': ['socket-client'],
    'socket framing': ['socket-byte-framing', 'socket-partial-write'],
    'socket reconnect': ['mcp-bridge'],
    'stop and cancel': ['socket-stop-queue'],
    'queued recordings': ['recording-take-queue'],
    'history ingress': ['socket-raw-speak-archive-ingress', 'speech-history-model'],
    'update admission': ['update-gate-admission', 'recognizer-update-admission'],
    'update fail open': ['update-gate-failopen'],
    'update install restore and dead admission': ['update-gate-bootstrap', 'update-gate-installer', 'update-gate-complete'],
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
    parser.add_argument('--native-output', type=Path, help='existing guarded e2e24 runner output from M1')
    parser.add_argument('--release', action='store_true', help='fail while native coverage is pending')
    parser.add_argument('--swift', action='store_true', help='run scoped native unit/offscreen cases, without UI driving')
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
            result = subprocess.run(['bun', 'test', *paths], cwd=ROOT, timeout=remaining, capture_output=True, text=True)
            output = (getattr(result, 'stdout', None) or '') + (getattr(result, 'stderr', None) or '')
            print(output, end='')
            skips = sum(int(n) for n in re.findall(r'(?m)^\s*(\d+) skip\s*$', output))
            rows.append(dict(flow=flow, cases=paths, status=('PASS_WITH_SKIPS' if skips else 'PASS') if result.returncode == 0 else 'FAIL', skips=skips))
    except subprocess.TimeoutExpired:
        rows.append(dict(flow='15 minute deadline', status='FAIL'))
    if args.swift:
        coverage = json.loads((ROOT / 'tests/fixtures/e2e-2.4/coverage.json').read_text())
        classes = sorted({case.split('/')[0] for row in coverage for case in row['cases']})
        remaining = 900 - (time.monotonic() - start)
        try:
            result = subprocess.run(['swift', 'test', '--package-path', 'flow-bar',
                '--scratch-path', '.build.noindex/swift', '--filter', '|'.join(classes)],
                cwd=ROOT, timeout=max(0.01, remaining), capture_output=True, text=True)
            output = (result.stdout or '') + (result.stderr or '')
            print(output, end='')
            skips = len(re.findall(r'Test skipped -', output))
            rows.append(dict(flow='scoped Swift flow coverage', cases=classes,
                             status=('PASS_WITH_SKIPS' if skips else 'PASS') if result.returncode == 0 else 'FAIL', skips=skips))
        except subprocess.TimeoutExpired:
            rows.append(dict(flow='scoped Swift flow coverage deadline', status='FAIL'))
    native_passed = False
    if args.native_output:
        try:
            qa = json.loads((args.native_output / 'qa-report.json').read_text())
            ledger = json.loads((args.native_output / 'ledger.json').read_text())
            native_passed = (qa.get('scenario') == 'e2e24' and qa.get('scenarioPassed') is True
                and ledger.get('scenario') == 'e2e24' and ledger.get('completed') is True
                and ledger.get('failures') == 0
                and 'e2e24' in ledger.get('coverage', {}).get('verifiedSurfaces', [])
                and not ledger.get('coverage', {}).get('missing')
                and not ledger.get('coverage', {}).get('missingSurfaces'))
        except (OSError, ValueError, TypeError):
            native_passed = False
        if not native_passed:
            rows.append(dict(flow='native e2e24 receipt', status='FAIL'))
    rows.extend(dict(flow=flow, status='PASS' if native_passed else 'M1-pending') for flow in PENDING)
    failed = any(row['status'] == 'FAIL' for row in rows)
    report = dict(seconds=round(time.monotonic()-start, 2), rows=rows,
                  releaseReady=not failed and native_passed and args.swift and not any(row.get('skips', 0) for row in rows), isolatedPassed=not failed)
    args.report.write_text(json.dumps(report, indent=2)+'\n')
    return 1 if failed or (args.release and not report["releaseReady"]) else 0

if __name__ == '__main__':
    raise SystemExit(main())
