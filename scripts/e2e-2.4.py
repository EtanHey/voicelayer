#!/usr/bin/env python3
"""Bounded isolated regression gate. Pending native coverage never counts as PASS."""
import argparse
from datetime import datetime
import hashlib
import plistlib
import json
import math
import os
import signal
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
    'history ingress': ['socket-raw-speak-archive-ingress'],
    'update admission': ['update-gate-admission', 'recognizer-update-admission'],
    'update fail open': ['update-gate-failopen'],
    'update install restore and dead admission': ['update-gate-bootstrap', 'update-gate-installer', 'update-gate-complete'],
    'launchd ownership': ['launchd-install', 'mcp-socket-owner'],
}
# Rows without an actual native case can never inherit a fixture PASS.
NATIVE_CASES = {
    'dictionary CRUD': ('pending-lane-A', ['dictionary']),
    'recognizer load/unload': ('pending-lane-A', ['recognizer']),
    'Settings History actions': ('pending-lane-A', ['history']),
    'pause/resume/word seek': ('pending-lane-B', ['playback']),
    'Replay': ('pending-lane-B', ['replay']),
    'same-take mute UI': ('pending-lane-A', ['mute']),
    'History fallback': ('pending-lane-A', ['fallback']),
    'queue spinner and cancel': ('pending-lane-A', ['queue']),
    'hide retains take': ('pending-lane-A', ['hide']),
    'typed feedback': ('pending-lane-A', ['typed']),
    'microphone reorder': ('pending-lane-A', ['microphone']),
    'permission revocation': ('pending-lane-A', ['permissions']),
    'History detents and scrolling': ('pending-lane-A', ['detents']),
    'recording mic and clock': ('pending-lane-A', ['wing']),
    'record after record': ('pending-lane-A', ['takes']),
    'History scope actions and dates': ('pending-lane-A', ['history-dictation', 'history-ask', 'history-speak']),
    'tooltip hover': ('pending-lane-A', ['tooltip-'+s for s in ['launcher','recording','transcribing','speaking','readback','history','settings']]),
    'History drag close': ('pending-lane-A', ['drag']),
    'Narration UI presentation': ('pending-lane-B', ['narration-speak','narration-ask','narration-read']),
    'F5 physical gestures': ('M1-pending', []),
    'native paste target and terminal typing': ('M1-pending', []),
    'installed update and restore': ('M1-pending', []),
    'NarrationLayer transport': ('pending-lane-B', []),
    'mute audio exclusion': ('pending-lane-A', []),
}

ATTEST_ROWS = {row for row, (_, surfaces) in NATIVE_CASES.items() if not surfaces}
ATTEST_SCHEMA = 'voicelayer.e2e24-attestation.v1'
# Only reviewed real producers may discharge a row. No producer exists yet for
# these complete flows; schema-valid hand-authored receipts remain UNPROVED.
ATTEST_PRODUCERS = {row: set() for row in ATTEST_ROWS}


def file_sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def iso_time(value):
    if not isinstance(value, str) or not re.fullmatch(r'\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?Z', value):
        raise ValueError('timestamp must be ISO UTC')
    return datetime.fromisoformat(value.replace('Z', '+00:00')).timestamp()


def validate_attestation(row, path, head, digest, build_time, candidate_app=None, now=None):
    if row not in ATTEST_ROWS:
        raise ValueError('unknown attestation row: ' + row)
    path = Path(path)
    try:
        data = json.loads(path.read_text())
        if not isinstance(data, dict):
            raise ValueError('receipt must be an object')
        t3 = data.get('schema') == 'voicelayer.t3-optf5-proof.v2'
        stamp = iso_time(data.get('timestamp'))
        current = time.time() if now is None else now
        if stamp < iso_time(build_time) or stamp < current - 86400 or stamp > current + 300:
            raise ValueError('receipt stale, pre-build or future-dated')
        if data.get('gitCommit' if t3 else 'head') != head:
            raise ValueError('receipt HEAD differs from candidate HEAD')
        if t3:
            if row != 'F5 physical gestures' or candidate_app is None:
                raise ValueError('T3 proof requires F5 row and --candidate-app')
            result = run_bounded(['bun', str(ROOT/'scripts/t3-optf5-proof.ts'), 'check',
                '--proof', str(path), '--app', str(candidate_app)], timeout=60, text=True)
            if result.returncode != 0:
                raise ValueError('existing T3 proof validator rejected receipt')
            status, reason = 'UNPROVED-native', 'Option+F5 proved only; tap/hold/lock/hint producer missing'
        else:
            if data.get('schema') != ATTEST_SCHEMA or data.get('row') != row or data.get('result') != 'PASS':
                raise ValueError('wrong schema, row or result')
            if not re.fullmatch(r'[0-9a-f]{64}', data.get('candidateBundleSha256', '')) or data['candidateBundleSha256'] != digest:
                raise ValueError('candidate bundle digest differs')
            if not isinstance(data.get('host'), str) or not data['host'].strip():
                raise ValueError('missing host')
            producer = data.get('producer')
            if not isinstance(producer, str) or not re.fullmatch(r'scripts/[A-Za-z0-9_./-]+', producer) or '..' in Path(producer).parts or not (ROOT/producer).resolve().is_relative_to(ROOT) or not (ROOT/producer).is_file():
                raise ValueError('missing/unsafe producer script')
            evidence = data.get('evidence')
            if not isinstance(evidence, list) or not evidence:
                raise ValueError('missing evidence')
            seen = set()
            for entry in evidence:
                if not isinstance(entry, dict):
                    raise ValueError('invalid evidence entry')
                relative = entry['path']
                target = (path.parent / relative).resolve()
                if (not isinstance(relative, str) or Path(relative).is_absolute()
                    or not target.is_relative_to(path.parent.resolve()) or not target.is_file()
                    or target in seen or not re.fullmatch(r'[0-9a-f]{64}', entry.get('sha256', ''))
                    or file_sha256(target) != entry['sha256']):
                    raise ValueError('missing, unsafe, duplicate or altered evidence')
                seen.add(target)
            status = 'PASS' if producer in ATTEST_PRODUCERS[row] else 'UNPROVED-native'
            reason = 'validated registered real producer' if status == 'PASS' else 'real producer not registered for this row'
        return dict(status=status, reason=reason, receipt=str(path.resolve()),
                    receiptSha256=file_sha256(path), schema=data['schema'], timestamp=data['timestamp'],
                    head=head, candidateBundleSha256=digest, producer=data.get('producer', 'scripts/t3-optf5-proof.ts'))
    except (OSError, KeyError, TypeError, subprocess.TimeoutExpired) as error:
        raise ValueError('invalid attestation: ' + str(error)) from error


def load_attestations(values, candidate_app):
    if not values:
        return {}
    if candidate_app is None:
        raise ValueError('--attest requires --candidate-app')
    head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    with (candidate_app/'Contents/Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    if not re.fullmatch(r'[0-9a-f]{40}', head) or info.get('GitCommit') != head:
        raise ValueError('candidate GitCommit must match current HEAD')
    result = run_bounded(['bun', str(ROOT/'scripts/t3-optf5-proof.ts'), 'bundle-digest',
                          '--app', str(candidate_app)], timeout=60, text=True)
    digest = result.stdout.strip()
    if result.returncode or not re.fullmatch(r'[0-9a-f]{64}', digest):
        raise ValueError('candidate bundle digest unavailable')
    attestations = {}
    for value in values:
        row, separator, receipt = value.partition('=')
        if not separator or not receipt or row in attestations:
            raise ValueError('expected unique --attest <row>=<receipt>')
        attestations[row] = validate_attestation(row, Path(receipt), head, digest,
                                                info.get('BuildTimeUTC'), candidate_app)
    return attestations


def native_rows(verified, attestations=None):
    attestations = attestations or {}
    return [dict(flow=flow, owner=owner, attestation=attestations.get(flow), surfaces=['e2e24:'+s for s in surfaces],
                 status='PASS' if surfaces and all('e2e24:'+s in verified for s in surfaces)
                 else (attestations.get(flow, {}).get('status', 'UNPROVED-native') if not surfaces else owner))
            for flow, (owner, surfaces) in NATIVE_CASES.items()]


def run_bounded(command, **kwargs):
    timeout = kwargs.pop('timeout')
    kwargs.pop('capture_output', None)
    with subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          start_new_session=True, **kwargs) as process:
        try:
            stdout, stderr = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                process.communicate(timeout=2)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.communicate()
            raise
        return subprocess.CompletedProcess(command, process.returncode, stdout, stderr)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--report', required=True, type=Path)
    parser.add_argument('--native-output', type=Path, help='existing guarded e2e24 runner output from M1')
    parser.add_argument('--release', action='store_true', help='fail while native coverage is pending')
    parser.add_argument('--swift', action='store_true', help='run scoped native unit/offscreen cases, without UI driving')
    parser.add_argument('--attest', action='append', default=[], metavar='ROW=RECEIPT', help='validate existing real proof; repeat per row')
    parser.add_argument('--candidate-app', type=Path, help='read-only candidate bundle, GitCommit must match HEAD')
    args = parser.parse_args()
    start = time.monotonic()
    try:
        attestations = load_attestations(args.attest, args.candidate_app)
    except (OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError) as error:
        parser.error(str(error))
    if args.report.exists():
        parser.error('report already exists')
    args.report.parent.mkdir(parents=True, exist_ok=True)
    rows = []
    try:
        for flow, suites in CASES.items():
            paths = [f'src/__tests__/{suite}.test.ts' for suite in suites]
            remaining = 900 - (time.monotonic() - start)
            if remaining <= 0:
                raise subprocess.TimeoutExpired('e2e deadline', 900)
            result = run_bounded(['bun', 'test', '--timeout', '30000', *paths], cwd=ROOT, timeout=remaining, capture_output=True, text=True)
            output = (getattr(result, 'stdout', None) or '') + (getattr(result, 'stderr', None) or '')
            print(output, end='')
            skips = sum(int(n) for n in re.findall(r'(?m)^\s*(\d+) skip\s*$', output))
            rows.append(dict(flow=flow, cases=paths, status=('PASS_WITH_SKIPS' if skips else 'PASS') if result.returncode == 0 else 'FAIL', skips=skips))
    except subprocess.TimeoutExpired:
        rows.append(dict(flow='15 minute deadline', status='FAIL'))
    if args.swift:
        coverage = json.loads((ROOT / 'tests/fixtures/e2e-2.4/coverage.json').read_text())
        classes = sorted({case for row in coverage for case in row['cases']})
        remaining = 900 - (time.monotonic() - start)
        try:
            result = run_bounded(['swift', 'test', '--package-path', 'flow-bar',
                '--scratch-path=.build.noindex/swift', '--filter', '|'.join(re.escape(case)+'$' for case in classes)],
                cwd=ROOT, timeout=max(0.01, remaining), capture_output=True, text=True)
            output = (result.stdout or '') + (result.stderr or '')
            print(output, end='')
            skips = len(re.findall(r'Test skipped -', output))
            executed = set(cls+'/'+method for cls,method in re.findall(r"Test Case '-\[[^ .]+\.([^ ]+) ([^]]+)\]' started", output))
            missing = sorted(set(classes) - executed)
            rows.append(dict(flow='scoped Swift flow coverage', cases=classes,
                             status=('PASS_WITH_SKIPS' if skips else 'PASS') if result.returncode == 0 and not missing else 'FAIL', skips=skips, missingCases=missing, executedCases=len(executed)))
        except subprocess.TimeoutExpired:
            rows.append(dict(flow='scoped Swift flow coverage deadline', status='FAIL'))
    native_passed = False
    verified = set()
    native_seconds = 0.0
    receipt_valid = False
    isolated_failed = any(row["status"] == "FAIL" for row in rows)
    if args.native_output:
        try:
            qa = json.loads((args.native_output / 'qa-report.json').read_text())
            ledger = json.loads((args.native_output / 'ledger.json').read_text())
            recording = json.loads((args.native_output / 'recording.json').read_text())
            native_seconds = float(recording['durationSeconds'])
            movie = recording['path']
            receipt_valid = (math.isfinite(native_seconds) and native_seconds > 0
                and recording.get('valid') is True and recording.get('runPassed') is True
                and isinstance(movie, str) and Path(movie).name == movie
                and (args.native_output / movie).is_file()
                and qa.get('scenario') == 'e2e24'
                and ledger.get('scenario') == 'e2e24' and ledger.get('completed') is True
                and ledger.get('failures') == 0
)
            if receipt_valid:
                verified = set(ledger.get('coverage', {}).get('verifiedSurfaces', []))
            native_passed = (receipt_valid and qa.get('scenarioPassed') is True
                and not ledger.get('coverage', {}).get('missing')
                and not ledger.get('coverage', {}).get('missingSurfaces'))
        except (OSError, ValueError, TypeError, KeyError):
            native_passed = False
        if not native_passed:
            if not receipt_valid:
                native_seconds = 0.0
            rows.append(dict(flow='native e2e24 receipt', status='FAIL'))
    rows.extend(native_rows(verified, attestations))
    local_seconds = time.monotonic() - start
    combined_seconds = local_seconds + native_seconds
    if native_passed and combined_seconds > 900:
        rows.append(dict(flow='combined 15 minute runtime', status='FAIL'))
    failed = any(row['status'] == 'FAIL' for row in rows)
    report = dict(seconds=round(local_seconds, 2), nativeSeconds=round(native_seconds, 2),
                  combinedSeconds=round(combined_seconds, 2), rows=rows,
                  releaseReady=not failed and native_passed and args.swift and all(row['status'] == 'PASS' for row in native_rows(verified, attestations)) and not any(row.get('skips', 0) for row in rows), isolatedPassed=not isolated_failed)
    args.report.write_text(json.dumps(report, indent=2)+'\n')
    return 1 if failed or (args.release and not report["releaseReady"]) else 0

if __name__ == '__main__':
    raise SystemExit(main())
