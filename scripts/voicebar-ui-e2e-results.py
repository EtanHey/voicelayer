#!/usr/bin/env python3
"""Xcode plist transport and fail-closed, per-action screenshot report (stdlib only)."""
import html
import json
import pathlib
import plistlib
import shutil
import subprocess
import sys


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


def report(directory, steps, manifest, recording=None):
    if not steps or [s['number'] for s in steps] != list(range(1, len(steps) + 1)):
        raise ValueError('Missing, duplicated or out-of-order action receipts')
    attachments = [a for test in manifest for a in test['attachments']]
    figures = []
    all_passed = True
    for step in steps:
        matches = [a for a in attachments if a['suggestedHumanReadableName'].startswith(step['attachment'])]
        if len(matches) != 1:
            raise ValueError(f"Expected one screenshot for {step['attachment']}, found {len(matches)}")
        name = matches[0]['exportedFileName']
        path = (directory / name).resolve()
        if not path.is_relative_to(directory.resolve()) or not path.is_file() or path.stat().st_size == 0:
            raise ValueError('Missing/unsafe screenshot file: ' + name)
        passed = step['passed'] and not matches[0]['isAssociatedWithFailure']
        all_passed = all_passed and passed
        status = 'SKIP' if step.get('skipped') and passed else 'PASS' if passed else 'FAIL'
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
    (directory / 'index.html').write_text('<!doctype html><meta charset="utf-8"><title>VoiceBar UI E2E</title>'
        '<style>body{font:16px system-ui;background:#16181d;color:#eee}main{display:grid;grid-template-columns:repeat(auto-fit,minmax(360px,1fr));gap:16px}figure{margin:0}img{width:100%}figcaption{padding:8px}</style>'
        '<h1>VoiceBar UI E2E — synthetic UI fixtures, no audio</h1>' + video + '<main>' + ''.join(figures) + '</main>')
    return all_passed


def export(output, sandbox):
    directory = output / 'screenshots'
    subprocess.run(['xcrun', 'xcresulttool', 'export', 'attachments', '--path', str(output / 'VoiceBar.xcresult'),
                    '--output-path', str(directory)], check=True)
    steps = json.loads((sandbox / 'steps.json').read_text())
    manifest = json.loads((directory / 'manifest.json').read_text())
    (output / 'steps.json').write_text(json.dumps(steps, indent=2))
    for name in ['coverage.json', 'events.json', 'dictionary.json', 'speech.json', 'processing.json']:
        if (sandbox / name).is_file():
            shutil.copy2(sandbox / name, output / name)
    # Completion receipt comes only after the final assertion; an aborted/empty run cannot pass.
    recording = json.loads((output / 'recording.json').read_text())
    if pathlib.Path(recording['path']).name != recording['path'] or not (output / recording['path']).is_file():
        raise ValueError('Recording file missing/unsafe')
    passed = report(directory, steps, manifest, recording)
    complete = (sandbox / 'completed').is_file() and (sandbox / 'completed').read_text().strip() == 'complete'
    if not complete:
        print('FAIL suite completion receipt missing')
    return passed and complete


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
