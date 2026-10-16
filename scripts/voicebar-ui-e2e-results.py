#!/usr/bin/env python3
"""Xcode plist transport and fail-closed, per-action screenshot report (stdlib only)."""
import html
import json
import pathlib
import plistlib
import re
import shutil
import subprocess
import sys


def expected_packet(step):
    expected = step.get('expectedFailure')
    if expected is None:
        return None
    packet = expected.get('packet')
    descriptions = expected.get('descriptions')
    if (step.get('passed') is not True or packet not in {'P14b', 'SEEK2', 'SEL1', 'P1e', 'P1f'}
            or not isinstance(descriptions, list) or not descriptions
            or not all(isinstance(d, str) and '[' + packet + ']' in d for d in descriptions)):
        raise ValueError('Invalid or unmatched expected product failure')
    if 'surfaces' in expected:
        surfaces = expected['surfaces']
        if (not isinstance(surfaces, list) or not surfaces
                or not all(isinstance(s, str) and s.strip() for s in surfaces)
                or len(surfaces) != len(set(surfaces))):
            raise ValueError('Invalid expected product-failure surfaces')
    return packet


def configure(output, app, sandbox):
    candidates = list((output / 'DerivedData/Build/Products').glob('*.xctestrun'))
    if len(candidates) != 1:
        raise ValueError('Expected exactly one built xctestrun')
    data = plistlib.loads(candidates[0].read_bytes())
    targets = [v for k, v in data.items() if k != '__xctestrun_metadata__' and isinstance(v, dict)]
    if 'TestConfigurations' in data:
        targets = [t for c in data['TestConfigurations'] for t in c['TestTargets']]
    if len(targets) != 1:
        raise ValueError('Expected exactly one test target')
    target = targets[0]
    env = target.setdefault('EnvironmentVariables', {})
    env.update(VOICEBAR_UIE2E_APP=str(app), VOICEBAR_UIE2E_ROOT=str(sandbox))
    # Moving the plist changes __TESTROOT__. Resolve it before writing the configured copy.
    def resolve(value):
        if isinstance(value, str):
            return value.replace('__TESTROOT__', str(candidates[0].parent))
        if isinstance(value, list):
            return [resolve(v) for v in value]
        if isinstance(value, dict):
            return {k: resolve(v) for k, v in value.items()}
        return value
    (output / 'UIE2E.xctestrun').write_bytes(plistlib.dumps(resolve(data)))


def report(directory, steps, manifest, recording=None, issues=()):
    issues = list(issues)
    if recording is not None and (recording.get('runPassed') is False or recording.get('cancelledSignals')):
        issues.append('FAIL recording run: ' + recording.get('error', 'test/recording run failed'))
    if not steps or [s['number'] for s in steps] != list(range(1, len(steps) + 1)):
        raise ValueError('Missing, duplicated or out-of-order action receipts')
    attachments = [a for test in manifest for a in test['attachments']]
    figures = []
    all_passed = not issues
    for step in steps:
        matches = [a for a in attachments if a['suggestedHumanReadableName'].startswith(step['attachment'])]
        if len(matches) != 1:
            raise ValueError(f"Expected one screenshot for {step['attachment']}, found {len(matches)}")
        name = matches[0]['exportedFileName']
        path = (directory / name).resolve()
        if not path.is_relative_to(directory.resolve()) or not path.is_file() or path.stat().st_size == 0:
            raise ValueError('Missing/unsafe screenshot file: ' + name)
        packet = expected_packet(step)
        passed = step['passed'] and (not matches[0]['isAssociatedWithFailure'] or packet is not None)
        all_passed = all_passed and passed
        status = ('XFAIL [' + packet + ']') if packet and passed else 'SKIP' if step.get('skipped') and passed else 'PASS' if passed else 'FAIL'
        caption = f"{step['number']:04d} {status} {step['name']}"
        print(caption)
        figures.append(f'<figure><a href="{html.escape(name, quote=True)}"><img loading="lazy" src="{html.escape(name, quote=True)}"></a><figcaption>{html.escape(caption)}</figcaption></figure>')
    video = ''
    if recording is not None:
        name = recording['path']
        if recording.get('valid') is not True or pathlib.Path(name).name != name:
            raise ValueError('Missing/invalid recording proof')
        video = (f'<p><a href="../{html.escape(name, quote=True)}">Screen recording (.mov)</a> — '
                 f'{recording["durationSeconds"]} s · {recording["bytes"]} bytes · no audio</p>')
    warnings = ''.join('<p role="alert">' + html.escape(issue) + '</p>' for issue in issues)
    (directory / 'index.html').write_text('<!doctype html><meta charset="utf-8"><title>VoiceBar UI E2E</title>'
        '<style>body{font:16px system-ui;background:#16181d;color:#eee}main{display:grid;grid-template-columns:repeat(auto-fit,minmax(360px,1fr));gap:16px}figure{margin:0}img{width:100%}figcaption{padding:8px}</style>'
        '<h1>VoiceBar UI E2E — synthetic UI fixtures, no audio</h1>' + warnings + video + '<main>' + ''.join(figures) + '</main>')
    return all_passed


def receipts(directory, manifest):
    """Read only retained XCTest JSON attachments; the signed runner writes no scratch files."""
    steps, ledgers, issues = {}, [], []
    for test in manifest:
        for attachment in test['attachments']:
            name = attachment['suggestedHumanReadableName']
            step_match = re.match(r'^UIE2E-RECEIPT-(\d{4,})(?=[_.]|$)', name)
            final = re.match(r'^UIE2E-LEDGER(?=[_.]|$)', name)
            if not (step_match or final):
                continue
            path = (directory / attachment['exportedFileName']).resolve()
            if not path.is_relative_to(directory.resolve()) or not path.is_file():
                raise ValueError('Missing/unsafe receipt attachment')
            data = json.loads(path.read_text())
            if step_match:
                number = int(step_match[1])
                if number in steps or data['number'] != number or type(data['passed']) is not bool:
                    raise ValueError('Duplicate/invalid action receipt')
                steps[number] = data
                expected_packet(data)
            else:
                ledgers.append(data)
            if attachment['isAssociatedWithFailure'] and not (step_match and expected_packet(data)):
                issues.append('FAIL receipt attachment associated with XCTest failure: ' + name)
    ordered = [steps[n] for n in sorted(steps)]
    if not ordered or sorted(steps) != list(range(1, len(steps) + 1)):
        raise ValueError('Missing action receipt attachments')
    if len(ledgers) > 1:
        raise ValueError('Duplicate final ledgers')
    ledger = ledgers[0] if ledgers else None
    if ledger is None:
        issues.append('FAIL suite completion receipt missing (aborted run)')
    else:
        if ledger['version'] != 1 or ledger['steps'] != ordered:
            raise ValueError('Final ledger differs from individual action receipts')
        coverage = ledger['coverage']
        expected_surfaces = coverage.get('expectedSurfaces', {})
        for step in ordered:
            if expected_packet(step) == 'P1f':
                # One gallery screenshot may prove several required failures, never an unknown scope.
                if any(expected_surfaces.get(surface) != 'P1f'
                       for surface in step['expectedFailure'].get('surfaces', [])):
                    raise ValueError('Aggregate P1f receipt names an unmatched expected surface')
        for surface, packet in expected_surfaces.items():
            if (surface in coverage.get('missingSurfaces', []) or surface in coverage.get('verifiedSurfaces', [])
                    or not any(expected_packet(s) == packet and (
                        s['expectedFailure'].get('surface') == surface
                        or (packet == 'P1f' and surface in s['expectedFailure'].get('surfaces', [])))
                        for s in ordered)):
                raise ValueError('Expected surface lacks its matching observed product-failure receipt')
        missing = sorted(set(coverage['observed']) - set(coverage['exercised']))
        if missing != sorted(coverage['missing']):
            raise ValueError('Inconsistent coverage ledger')
        if missing:
            issues.append('FAIL unexercised controls: ' + ', '.join(missing))
        if coverage.get('missingSurfaces'):
            issues.append('FAIL unverified surfaces: ' + ', '.join(sorted(coverage['missingSurfaces'])))
        if ledger['completed'] is not True or ledger['failures'] != 0:
            issues.append('FAIL suite completion or teardown assertions failed')
        issues.extend('KNOWN VISUAL GAP: ' + gap for gap in ledger['knownVisualGaps'])
    return ordered, ledger, issues


def export(output, sandbox):
    directory = output / 'screenshots'
    subprocess.run(['xcrun', 'xcresulttool', 'export', 'attachments', '--path', str(output / 'VoiceBar.xcresult'),
                    '--output-path', str(directory)], check=True)
    manifest = json.loads((directory / 'manifest.json').read_text())
    steps, ledger, issues = receipts(directory, manifest)
    (output / 'steps.json').write_text(json.dumps(steps, indent=2))
    if ledger is not None:
        (output / 'ledger.json').write_text(json.dumps(ledger, indent=2))
        (output / 'coverage.json').write_text(json.dumps(ledger['coverage'], indent=2))
    # These receipts are written by the isolated QA app, not the sandboxed XCTest runner.
    for name in ['events.json', 'dictionary.json', 'speech.json', 'processing.json']:
        if (sandbox / name).is_file():
            shutil.copy2(sandbox / name, output / name)
    # Completion receipt comes only after the final assertion; an aborted/empty run cannot pass.
    recording = json.loads((output / 'recording.json').read_text())
    if pathlib.Path(recording['path']).name != recording['path'] or not (output / recording['path']).is_file():
        raise ValueError('Recording file missing/unsafe')
    for issue in issues:
        print(issue)
    return report(directory, steps, manifest, recording, issues)


if __name__ == '__main__':
    try:
        if sys.argv[1] == 'configure':
            configure(*(pathlib.Path(p).resolve() for p in sys.argv[2:5]))
        elif sys.argv[1] == 'export':
            if not export(*(pathlib.Path(p).resolve() for p in sys.argv[2:4])):
                sys.exit(1)
        else:
            raise ValueError('Expected configure or export')
    except Exception as error:
        print('FAIL UIE2E results:', error, file=sys.stderr)
        sys.exit(1)
