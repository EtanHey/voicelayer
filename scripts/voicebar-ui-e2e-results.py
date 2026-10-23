#!/usr/bin/env python3
"""Xcode plist transport and fail-closed, per-action screenshot report (stdlib only)."""
import argparse
import html
import json
import pathlib
import plistlib
import re
import shutil
import subprocess
import sys


SCENARIOS = {'full': 'testFullUIOnlyFlow', 'focused-338': 'testFocused338StateGallery', 'hide1': 'testHide1VisualFlow', 'gate2246': 'testGate2246Flow'}


def selected_scenario(output, scenario=None):
    path = output / 'scenario.json'
    recorded = json.loads(path.read_text())['scenario'] if path.exists() else None
    chosen = scenario if scenario is not None else recorded if recorded is not None else 'full'
    if chosen not in SCENARIOS or (recorded is not None and recorded != chosen):
        raise ValueError('Invalid or conflicting UIE2E scenario: ' + str(chosen))
    return chosen


def write_scenario(output, scenario=None):
    scenario = selected_scenario(output, scenario)
    metadata = dict(version=1, scenario=scenario, scope=scenario,
                    onlyTestIdentifiers=['VoiceBarFlowTests/' + SCENARIOS[scenario]])
    (output / 'scenario.json').write_text(json.dumps(metadata, indent=2, sort_keys=True) + '\n')
    return scenario


def expected_packet(step):
    expected = step.get('expectedFailure')
    if expected is None:
        return None
    packet = expected.get('packet')
    descriptions = expected.get('descriptions')
    if (step.get('passed') is not True or packet not in {'P14b', 'SEL1', 'P1e', 'P1f'}
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


def configure(output, app, sandbox, scenario=None):
    scenario = selected_scenario(output, scenario)
    guard = load_guard()
    derived = guard.derived_data_path(output)
    candidates = list((derived / 'Build/Products').glob('*.xctestrun'))
    if len(candidates) != 1:
        raise ValueError('Expected exactly one built xctestrun')
    data = plistlib.loads(candidates[0].read_bytes())
    targets = [v for k, v in data.items() if k != '__xctestrun_metadata__' and isinstance(v, dict)]
    if 'TestConfigurations' in data:
        targets = [t for c in data['TestConfigurations'] for t in c['TestTargets']]
    if len(targets) != 1:
        raise ValueError('Expected exactly one test target')
    target = targets[0]
    # XCTest's Automatic Screen Capture = Off is keepNever (both screenshots and video).
    # Override inherited settings at configuration AND target levels; keep explicit user stills.
    def disable_capture(value):
        if isinstance(value, dict):
            for key in ('SystemAttachmentLifetime', 'PreferredScreenCaptureFormat'):
                if key in value:
                    value[key] = 'keepNever' if key == 'SystemAttachmentLifetime' else 'screenshots'
            for child in value.values():
                disable_capture(child)
        elif isinstance(value, list):
            for child in value:
                disable_capture(child)
    disable_capture(data)
    target.update(SystemAttachmentLifetime='keepNever', PreferredScreenCaptureFormat='screenshots',
                  UserAttachmentLifetime='keepAlways')
    # Replace generated/inherited selections: never run full and focused together.
    target['OnlyTestIdentifiers'] = ['VoiceBarFlowTests/' + SCENARIOS[scenario]]
    target.pop('SkipTestIdentifiers', None)
    env = target.setdefault('EnvironmentVariables', {})
    env.update(VOICEBAR_UIE2E_APP=str(app), VOICEBAR_UIE2E_ROOT=str(sandbox),
               VOICEBAR_UIE2E_SCENARIO=scenario)
    if guard.required(scenario, app / 'Contents/Info.plist'):
        env['VOICEBAR_UIE2E_DEVICE_GUARD'] = str(guard.verify(pathlib.Path(__file__).resolve().parent.parent, output))
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
    write_scenario(output, scenario)


def inventory_proven(proof):
    """A successful CG on-screen inventory at the step with zero windows owned by the proven QA PID."""
    return (isinstance(proof, dict) and proof.get('cgInventory') == 'ok'
            and type(proof.get('onScreenQAWindows')) is int and proof['onScreenQAWindows'] == 0
            and type(proof.get('qaPid')) is int and proof['qaPid'] > 0
            and isinstance(proof.get('qaBirth'), list) and len(proof['qaBirth']) == 2
            and all(type(n) is int for n in proof['qaBirth'])
            and proof['qaBirth'][0] > 0 and 0 <= proof['qaBirth'][1] < 1000000)


def absence_proven(proof):
    return inventory_proven(proof) and proof.get('pidLifetime') == 'alive'


def termination_proven(proof):
    return (inventory_proven(proof) and proof.get('pidLifetime') == 'ended'
            and proof.get('visibleOwnerPaths') == 'non-qa')


def report(directory, steps, manifest, recording=None, issues=(), limitations=(), scenario='full'):
    if scenario not in SCENARIOS:
        raise ValueError('Invalid UIE2E report scenario')
    issues = list(issues)
    if recording is not None and (recording.get('runPassed') is False or recording.get('cancelledSignals')):
        issues.append('FAIL recording run: ' + recording.get('error', 'test/recording run failed'))
    if not steps or [s['number'] for s in steps] != list(range(1, len(steps) + 1)):
        raise ValueError('Missing, duplicated or out-of-order action receipts')
    attachments = [a for test in manifest for a in test['attachments']]
    figures = []
    all_passed = not issues
    for step in steps:
        capture = step.get('capture')
        contract = step.get('evidenceContract')
        declared = contract in {'visible', 'hidden-alive', 'terminated'}
        matches = [a for a in attachments if a['suggestedHumanReadableName'].startswith(step['attachment'])]
        # Every published frame is a window-ID capture of the proven QA process; never a desktop crop.
        if not isinstance(capture, dict) or capture.get('source') != 'qa-window-id' \
                or capture.get('status') not in ('PROVEN', 'NOT_PROVEN') \
                or (capture['status'] == 'PROVEN' and not (isinstance(capture.get('windows'), list) and capture['windows'])):
            raise ValueError('Frame capture source is not the QA window/region: ' + str(step.get('attachment')))
        if capture['status'] == 'NOT_PROVEN':
            if matches:
                raise ValueError('NOT_PROVEN frame carries an image: ' + step['attachment'])
            # Lead ruling: only a step expecting hidden QA, with a positive expected-absent proof, may pass.
            allowed = ((contract == 'hidden-alive' and absence_proven(capture.get('absenceProof')))
                       or (contract == 'terminated' and termination_proven(capture.get('terminationProof'))))
            status = 'ABSENT (proven)' if allowed else 'FAIL VISUAL NOT_PROVEN'
            caption = f"{step['number']:04d} {status} ({capture.get('reason', 'unproven')}) {step['name']}"
            print(caption)
            all_passed = all_passed and step['passed'] and allowed
            figures.append(f'<figure><figcaption>{html.escape(caption)}</figcaption></figure>')
            continue
        if len(matches) != 1:
            raise ValueError(f"Expected one screenshot for {step['attachment']}, found {len(matches)}")
        name = matches[0]['exportedFileName']
        path = (directory / name).resolve()
        if not path.is_relative_to(directory.resolve()) or not path.is_file() or path.stat().st_size == 0:
            raise ValueError('Missing/unsafe screenshot file: ' + name)
        packet = expected_packet(step)
        rejected_waiver = scenario == 'focused-338' and packet is not None
        passed = (declared and contract != 'terminated' and step['passed'] and (not matches[0]['isAssociatedWithFailure'] or packet is not None)
                  and not rejected_waiver)
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
        source = recording.get('captureSource') or {}
        if (source.get('kind') != 'application' or source.get('bundle') != 'com.voicelayer.voicebar.uie2e'
                or source.get('fullDisplay') is not False or not source.get('executable') or not source.get('observedPids')):
            raise ValueError('Recording capture source is not the QA app window set')
        video = (f'<p><a href="../{html.escape(name, quote=True)}">Screen recording (.mov)</a> — '
                 f'{recording["durationSeconds"]} s · {recording["bytes"]} bytes · no audio</p>')
    warnings = ''.join('<p role="alert">' + html.escape(issue) + '</p>' for issue in issues)
    notes = ''.join('<p role="note">' + html.escape(note) + '</p>' for note in limitations)
    scope = ('<p role="note">Focused #338 scope only; full release coverage NOT_PROVEN.</p>'
             if scenario == 'focused-338' else '')
    (directory / 'index.html').write_text('<!doctype html><meta charset="utf-8"><title>VoiceBar UI E2E — ' + scenario + '</title>'
        '<style>body{font:16px system-ui;background:#16181d;color:#eee}main{display:grid;grid-template-columns:repeat(auto-fit,minmax(360px,1fr));gap:16px}figure{margin:0}img{width:100%}figcaption{padding:8px}</style>'
        '<h1>VoiceBar UI E2E — ' + scenario + ' — synthetic UI fixtures, no audio</h1>' + scope + warnings + notes + video + '<main>' + ''.join(figures) + '</main>')
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


def load_guard():
    import importlib.util
    spec = importlib.util.spec_from_file_location('device_guard', pathlib.Path(__file__).with_name('voicebar-ui-e2e-guard-proof.py'))
    guard = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(guard)
    return guard


GUARD_INSTALLED = 'voicebar-no-device-guard-v1:installed'


def guard_launch_log(sandbox, launch):
    """Launch 1 keeps the supervisor-watched path; every relaunch gets its own fresh log."""
    return sandbox / ('no-device-guard.log' if launch == 1 else 'no-device-guard-launch-%d.log' % launch)


def guard_launch_issues(sandbox, launches):
    """Require the ledger's launch sequence, never infer it from surviving log files."""
    issues = []
    expected = {guard_launch_log(sandbox, n).name for n in range(1, launches + 1)}
    present = {path.name for path in sandbox.glob('no-device-guard*.log')}
    extra = sorted(present - expected)
    if extra:
        issues.append('FAIL unexpected no-device guard launch logs: ' + ', '.join(extra))
    for launch in range(1, launches + 1):
        path = guard_launch_log(sandbox, launch)
        if not path.is_file():
            issues.append('FAIL no-device guard receipt missing for launch %d' % launch)
            continue
        lines = path.read_text().splitlines()
        trips = [line for line in lines if line != GUARD_INSTALLED]
        if trips:
            issues.append('FAIL device tripwire on launch %d: %s' % (launch, ', '.join(trips)))
        elif lines != [GUARD_INSTALLED]:
            issues.append('FAIL launch %d guard receipt is not exactly one install marker' % launch)
    return issues


def guard_receipt_steps(scenario, launches, gate_build=False):
    """In-app tripwire receipts: per QA launch, and before/after the scenario's gate fixtures."""
    required = {'GUARD launch %d %s' % (n, phase) for n in range(1, launches + 1)
                for phase in ['installed', 'no tripwire']}
    prefix = {'hide1': 'HIDE1VIS', 'gate2246': 'GATE2246'}.get(scenario, 'GATE2245' if gate_build else None)
    if prefix is not None:
        required |= {prefix + ' no-device guard installed before fixtures',
                     prefix + ' no device-start or process tripwire invoked'}
    return required


def guard_export_issues(scenario, sandbox, step_names):
    plist = sandbox / 'VoiceBarQA.app/Contents/Info.plist'
    gate_build = plist.is_file() and plistlib.loads(plist.read_bytes()).get('UIE2EGate2245') is True
    if not (gate_build or load_guard().required(scenario)):
        return []
    launch_steps = [name for name in step_names
                    if name in {'launch isolated QA app', 'relaunch isolated QA app'}]
    launches = len(launch_steps)
    issues = guard_launch_issues(sandbox, launches)
    if not launch_steps or launch_steps != ['launch isolated QA app'] + ['relaunch isolated QA app'] * (launches - 1):
        issues.append('FAIL invalid or missing recorded QA launch sequence')
    required = guard_receipt_steps(scenario, launches, gate_build)
    missing = sorted(required - set(step_names))
    if missing:
        issues.append('FAIL no-device guard receipt steps missing: ' + ', '.join(missing))
    invalid = sorted({name for name in step_names if name.startswith('GUARD launch ')
                      and (name not in required or step_names.count(name) != 1)})
    if invalid:
        issues.append('FAIL unexpected or duplicate no-device guard receipt steps: ' + ', '.join(invalid))
    return issues


def verify_no_system_capture(output, scenario):
    """Inspect metadata, including failed/aborted test summaries, BEFORE materializing any payload.

    Never traverse payloadRef/diagnosticsRef. Unknown attachment types are unproven media;
    only the known non-media XCTest types and our explicit PNG/JSON names are permitted.
    """
    def read(ident=None):
        command = ['xcrun', 'xcresulttool', 'get', 'object', '--legacy', '--format', 'json',
                   '--path', str(output / 'VoiceBar.xcresult')]
        return json.loads(subprocess.check_output(command + (['--id', ident] if ident else []),
                                                 text=True, stderr=subprocess.PIPE))
    try:
        pending, seen = [read()], set()
        def walk(value):
            if isinstance(value, list):
                for child in value:
                    walk(child)
            elif isinstance(value, dict):
                if value.get('_type', {}).get('_name') == 'ActionTestAttachment':
                    uti = value.get('uniformTypeIdentifier', {}).get('_value')
                    name = value.get('name', {}).get('_value', '')
                    own_png = uti == 'public.png' and re.fullmatch(r'UIE2E-\d{4,}', name)
                    non_media = uti in {'public.json', 'public.plain-text', 'com.apple.dt.xctest.element-snapshot',
                                        'com.apple.dt.xctest.synthesized-event-record'}
                    if not (own_png or non_media):
                        raise ValueError('unexpected-system-capture')
                for key, child in value.items():
                    if key in {'testsRef', 'summaryRef'}:
                        ident = child['id']['_value']
                        if not isinstance(ident, str) or not ident:
                            raise ValueError('attachment-inventory-not-proven')
                        if ident not in seen:
                            seen.add(ident)
                            pending.append(read(ident))
                    elif key not in {'payloadRef', 'diagnosticsRef'}:
                        walk(child)
        while pending:
            walk(pending.pop())
        if not seen:
            raise ValueError('attachment-inventory-not-proven')
    except Exception as error:
        reason = 'unexpected-system-capture' if str(error) == 'unexpected-system-capture' else 'attachment-inventory-not-proven'
        # Do not persist attachment names or other potentially private system metadata.
        (output / 'qa-report.json').write_text(json.dumps(dict(scenario=scenario, scope=scenario,
            scenarioPassed=False, verdict='FAIL', fullReleasePass=False, issues=['FAIL ' + reason],
            resultBundle=str((output / 'VoiceBar.xcresult').resolve()))) + '\n')
        raise ValueError(reason) from None


def export(output, sandbox, scenario=None):
    scenario = selected_scenario(output, scenario)
    verify_no_system_capture(output, scenario)
    directory = output / 'screenshots'
    subprocess.run(['xcrun', 'xcresulttool', 'export', 'attachments', '--path', str(output / 'VoiceBar.xcresult'),
                    '--output-path', str(directory), '--filter', 'UIE2E-*'], check=True)
    manifest = json.loads((directory / 'manifest.json').read_text())
    steps, ledger, issues = receipts(directory, manifest)
    if ledger is not None:
        labels = [ledger.get('scenario'), ledger.get('scope'), ledger['coverage'].get('scenario')]
        if ((scenario in {'focused-338', 'hide1', 'gate2246'} and labels != [scenario] * 3)
                or any(label is not None and label != scenario for label in labels)):
            raise ValueError('Ledger scenario/scope differs from selected scenario: ' + scenario)
    if scenario == 'focused-338':
        if any(step.get('skipped') for step in steps):
            issues.append('FAIL focused-338 cannot skip required gallery capabilities')
        waived_packets = sorted({packet for step in steps if (packet := expected_packet(step)) is not None})
        if waived_packets:
            issues.append('FAIL focused-338 cannot use expected-failure waivers after P1e/P1f merge: '
                          + ', '.join(waived_packets))
    if scenario == 'gate2246':
        required = {'GATE2246 HIDE ' + name + ' ' + phase
                    for name in ['user-f5', 'user-ask', 'unknown', 'background', 'recovered', 'visible']
                    for phase in ['before', 'failure', 'shown']}
        required |= {'GATE2246 SEL ' + name for name in ['same-hash', 'different', 'pending', 'fast-bc', 'no-hash', 'busy']}
        if not required.issubset({step['name'] for step in steps}):
            issues.append('FAIL gate2246 missing required evidence')
        if any(step.get('skipped') or expected_packet(step) is not None for step in steps):
            issues.append('FAIL gate2246 cannot skip or waive a case')
    if scenario == 'hide1':
        required = {'HIDE1VIS ' + event + ' ' + phase
                    for event in ['speaking', 'preparing', 'readback', 'error', 'reconnect', 'notes', 'wizard']
                    for phase in ['before', 'hidden', 'shown']}
        if not required.issubset({step['name'] for step in steps}):
            issues.append('FAIL hide1 missing required before/hidden/shown evidence')
        if any(step.get('skipped') or expected_packet(step) is not None for step in steps):
            issues.append('FAIL hide1 cannot skip or waive a case')
    issues += guard_export_issues(scenario, sandbox, [step['name'] for step in steps])
    (output / 'steps.json').write_text(json.dumps(steps, indent=2))
    if ledger is not None:
        (output / 'ledger.json').write_text(json.dumps(ledger, indent=2))
        (output / 'coverage.json').write_text(json.dumps(ledger['coverage'], indent=2))
    # These receipts are written by the isolated QA app, not the sandboxed XCTest runner.
    for name in ['events.json', 'dictionary.json', 'speech.json', 'processing.json',
                 'gallery.json', 'focused-scope.json']:
        source = sandbox / name
        if not source.is_file():
            if scenario == 'focused-338' and name == 'gallery.json':
                raise ValueError('Missing focused-338 gallery.json receipt; gallery capability cannot skip')
            continue
        if not source.resolve().is_relative_to(sandbox.resolve()):
            raise ValueError('Unsafe sandbox receipt: ' + name)
        if name == 'gallery.json' and scenario == 'focused-338':
            gallery = json.loads(source.read_text())
            if not isinstance(gallery, dict) or gallery.get('scenario') != scenario:
                raise ValueError('Gallery receipt scenario differs from focused-338')
        shutil.copy2(source, output / name)
    # Completion receipt comes only after the final assertion; an aborted/empty run cannot pass.
    recording = json.loads((output / 'recording.json').read_text())
    if pathlib.Path(recording['path']).name != recording['path'] or not (output / recording['path']).is_file():
        raise ValueError('Recording file missing/unsafe')
    for issue in issues:
        print(issue)
    passed = report(directory, steps, manifest, recording, issues,
                    ledger.get('limitations', []) if ledger else [], scenario)
    write_scenario(output, scenario)
    qa = dict(version=1, scenario=scenario, scope=scenario, scenarioPassed=passed,
              verdict=('FOCUSED_SCENARIO_PASS' if scenario in {'focused-338', 'hide1', 'gate2246'} else 'FULL_UI_SCENARIO_PASS') if passed else 'FAIL',
              fullReleasePass=False, fullReleaseCoverage='NOT_PROVEN', issues=issues,
              # Steps with no proven QA window to capture: no frame was taken (never a desktop crop).
              visualNotProven=[s['number'] for s in steps if (s.get('capture') or {}).get('status') == 'NOT_PROVEN'])
    (output / 'qa-report.json').write_text(json.dumps(qa, indent=2, sort_keys=True) + '\n')
    return passed


if __name__ == '__main__':
    try:
        parser = argparse.ArgumentParser(description=__doc__)
        commands = parser.add_subparsers(dest='command', required=True)
        for command, paths in [('scenario', ['output']), ('configure', ['output', 'app', 'sandbox']),
                               ('export', ['output', 'sandbox'])]:
            sub = commands.add_parser(command)
            for name in paths:
                sub.add_argument(name, type=lambda p: pathlib.Path(p).resolve())
            sub.add_argument('--scenario', choices=SCENARIOS)
        args = parser.parse_args()
        if args.command == 'scenario':
            write_scenario(args.output, args.scenario)
        elif args.command == 'configure':
            configure(args.output, args.app, args.sandbox, args.scenario)
        elif not export(args.output, args.sandbox, args.scenario):
            sys.exit(1)
    except Exception as error:
        print('FAIL UIE2E results:', error, file=sys.stderr)
        sys.exit(1)
