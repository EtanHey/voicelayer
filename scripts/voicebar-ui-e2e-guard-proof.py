#!/usr/bin/env python3
"""Build/test the no-device interposer; bind launch authorization to exact build bytes."""
import argparse
import datetime
import hashlib
import json
import os
import pathlib
import plistlib
import subprocess

PATHS = [
    'init', 'inputNode', 'prepare', 'startAndReturnError:',
    'requestAccessForMediaType:completionHandler:', 'defaultDeviceWithMediaType:',
    'devicesWithMediaType:', 'AudioDeviceStart', 'AudioOutputUnitStart',
    'AudioUnitInitialize', 'AudioObjectGetPropertyData', 'AudioObjectGetPropertyDataSize',
    'AudioObjectSetPropertyData', 'posix_spawn', 'posix_spawnp', 'execve', 'NSTask',
]
# Every scenario whose fixture constructs the real AppDelegate (UIE2EGate2245).
GUARDED_SCENARIOS = {'hide1', 'gate2246'}
SOURCES = [
    'scripts/voicebar-ui-e2e-device-guard.m', 'scripts/voicebar-ui-e2e-device-probe.m',
    'scripts/voicebar-ui-e2e-guard-proof.py', 'scripts/voicebar-ui-e2e-run.py',
    'scripts/voicebar-ui-e2e-results.py', 'scripts/voicebar-ui-e2e.sh',
    'scripts/voicebar-ui-e2e-supervisor.py', 'scripts/voicebar-ui-e2e-resident.swift',
    'scripts/voicebar-ui-e2e-permissions.swift',
    'flow-bar/Sources/VoiceBar/VoiceBarApp.swift',
    'flow-bar/Sources/VoiceBar/UIE2EHost.swift', 'flow-bar/Sources/VoiceBar/UIE2EGate2245.swift',
    'flow-bar/Sources/VoiceBarUI/AudioLevelMonitor.swift', 'flow-bar/Sources/VoiceBarUI/AudioStreamable.swift',
    'flow-bar/UIE2E/VoiceBarUIE2ETests/VoiceBarFlowTests.swift',
    'flow-bar/UIE2E/VoiceBarUIE2ETests/Gate2245Tests.swift',
]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def derived_data_path(output):
    """Use the shell's recorded location; only pre-metadata runs use the legacy layout."""
    metadata = output / 'derived-data-path.txt'
    if not metadata.exists():
        return (output / 'DerivedData').resolve()
    recorded = metadata.read_text().strip()
    if not recorded or not pathlib.Path(recorded).is_absolute():
        raise ValueError('Expected an absolute recorded DerivedData path')
    return pathlib.Path(recorded).resolve()


def xctest_runner_path(derived):
    return (derived / 'Build/Products/Debug/VoiceBarUIE2ETests-Runner.app'
            '/Contents/MacOS/VoiceBarUIE2ETests-Runner').resolve()


def identities(repo, output):
    sandbox = pathlib.Path((output / 'sandbox-path.txt').read_text().strip())
    files = [repo / path for path in SOURCES]
    files += sorted((repo / 'flow-bar/Sources/VoiceBar').glob('*.swift'))
    files += sorted((repo / 'flow-bar/Sources/VoiceBarUI').glob('*.swift'))
    binary = sandbox / 'VoiceBarQA.app/Contents/MacOS/VoiceBar'
    files += [binary, output / 'device-guard.dylib',
              output / 'device-guard-probe', output / 'voicebar-ui-e2e-resident',
              output / 'voicebar-ui-e2e-permissions', sandbox / 'VoiceBarQA.app/Contents/Info.plist']
    if b'voicebar_no_device_guard_version' not in binary.read_bytes():
        raise ValueError('QA binary lacks the mandatory runtime guard check')
    # Include the actual UI test executable, not just its source.
    derived = derived_data_path(output)
    binaries = list((derived / 'Build/Products').glob(
        '**/VoiceBarUIE2ETests.xctest/Contents/MacOS/VoiceBarUIE2ETests'))
    if len(binaries) != 1:
        raise ValueError('Expected exactly one UI test executable')
    files += binaries + [xctest_runner_path(derived)]
    metadata = output / 'derived-data-path.txt'
    if metadata.exists():
        files.append(metadata)
    return {str(path.resolve()): digest(path) for path in files}


def build(repo, output):
    common = ['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-framework', 'Foundation',
              '-framework', 'AVFoundation', '-framework', 'AudioToolbox', '-framework', 'CoreAudio']
    for source, product, flags in [('device-guard', 'device-guard.dylib', ['-dynamiclib']),
                                    ('device-probe', 'device-guard-probe', [])]:
        result = subprocess.run(common + flags + [str(repo / ('scripts/voicebar-ui-e2e-' + source + '.m')),
                                                 '-o', str(output / product)], capture_output=True, text=True)
        (output / (product + '-build.log')).write_text(result.stdout + result.stderr)
        result.check_returncode()
    tests = []
    env = os.environ.copy()
    env['DYLD_INSERT_LIBRARIES'] = str(output / 'device-guard.dylib')
    for number, path in enumerate(PATHS):
        receipt = output / ('guard-probe-' + str(number) + '.log')
        if receipt.exists():
            raise ValueError('Refusing to overwrite guard probe evidence')
        env['VOICEBAR_UIE2E_GUARD_RECEIPT'] = str(receipt)
        result = subprocess.run([str(output / 'device-guard-probe'), path], env=env,
                                capture_output=True, text=True, timeout=10)
        events = receipt.read_text().splitlines() if receipt.exists() else []
        expected = 'posix_spawn' if path == 'NSTask' else path
        passed = result.returncode == 86 and events == ['voicebar-no-device-guard-v1:installed', expected]
        tests.append(dict(path=path, exit=result.returncode, events=events, passed=passed,
                          stderr=result.stderr))
        (output / 'device-guard-tests.json').write_text(json.dumps(tests, indent=2) + '\n')
        if not passed:
            raise ValueError('No-device tripwire self-test failed: ' + path)
    proof = dict(version=1, paths=PATHS, tests=tests, identities=identities(repo, output))
    (output / 'device-guard-proof.json').write_text(json.dumps(proof, indent=2) + '\n')
    print('PASS device guard: ' + str(len(tests)) + ' actual blocked API calls, zero devices opened')


def verify(repo, output):
    proof = json.loads((output / 'device-guard-proof.json').read_text())
    if (proof.get('version') != 1 or proof.get('paths') != PATHS
            or len(proof.get('tests', [])) != len(PATHS)
            or any(t.get('path') != p or t.get('passed') is not True or t.get('exit') != 86
                   or t.get('events') != ['voicebar-no-device-guard-v1:installed', 'posix_spawn' if p == 'NSTask' else p]
                   for t, p in zip(proof['tests'], PATHS))
            or proof.get('identities') != identities(repo, output)):
        raise ValueError('Missing, stale or invalid no-device guard proof; native launch refused')
    return output / 'device-guard.dylib'


def required(scenario, info_plist=None):
    """A guarded scenario, or any build whose plist says it compiled GATE2245 (fail closed)."""
    if scenario in GUARDED_SCENARIOS:
        return True
    if info_plist is not None and pathlib.Path(info_plist).exists():
        return plistlib.loads(pathlib.Path(info_plist).read_bytes()).get('UIE2EGate2245') is True
    return False


def authorize(repo, output, scenario, info_plist=None):
    """Refuse a guarded native launch unless the exact built guard passed its probes."""
    if not required(scenario, info_plist):
        return None
    library = verify(repo, output)
    if scenario == 'gate2246':
        # The lead authorized ONE gate2246 retry after the seam. Claim it atomically, once.
        with (output / 'native-retry-claimed.json').open('x') as receipt:
            json.dump({'authorizedBy': 'GATE2246B-BRIEF and QA-only seam ruling',
                       'claimedAt': datetime.datetime.now(datetime.timezone.utc).isoformat()}, receipt)
    return library


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['build', 'verify'])
    parser.add_argument('output', type=pathlib.Path)
    args = parser.parse_args()
    repo = pathlib.Path(__file__).resolve().parent.parent
    if args.action == 'build':
        build(repo, args.output.resolve())
    else:
        print(verify(repo, args.output.resolve()))
