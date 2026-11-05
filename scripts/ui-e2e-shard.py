#!/usr/bin/env python3
"""Build once per physical host, shard recorded UIE2E scenarios across isolated guests."""
import argparse
import concurrent.futures
import hashlib
import importlib.util
import json
import os
import pathlib
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid

SCENARIOS = {'full': 'testFullUIOnlyFlow', 'focused-338': 'testFocused338StateGallery',
             'hide1': 'testHide1VisualFlow', 'gate2246': 'testGate2246Flow'}
HERE = pathlib.Path(__file__).resolve()
sys.path.insert(0, str(HERE.parent))
import ui_e2e_shard_io as io
from ui_e2e_shard_io import (
    command, ssh, case_budget, pointer_model, provenance, verify_provenance,
    guest_relative, collect_remote, collect_tests, emit_result, parse_result, cancel_owned,
    SCENARIO_BUDGET_SECONDS, CLEANUP_SECONDS, TRANSFER_SECONDS, BUILD_SECONDS, DISK_FLOOR, CANCELLED, RESULT_MARKER)


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def plan(config, durations=None, serial=False, host_only=False):
    if serial and host_only:
        raise ValueError('--serial-vm and --host-only are mutually exclusive')
    hosts = {h['id']: h for h in config['hosts']}
    envs = config['environments']
    if len(hosts) != len(config['hosts']) or len({e['id'] for e in envs}) != len(envs):
        raise ValueError('Duplicate host/environment id')
    for env in envs:
        if env['host'] not in hosts or env['kind'] not in ('host', 'tart'):
            raise ValueError('Unknown environment host/kind')
        if not re.fullmatch(r'[A-Za-z0-9_-]+', env['id']):
            raise ValueError('Unsafe environment id')
    scenarios = config.get('scenarios', list(SCENARIOS))
    if not scenarios or len(set(scenarios)) != len(scenarios) or any(s not in SCENARIOS for s in scenarios):
        raise ValueError('Expected distinct existing UIE2E scenarios')
    # Cases are pointer-bearing; a host requires explicit authority AND a permitted model.
    for env in envs:
        if env['kind'] == 'host' and env.get('pointer_ok'):
            pointer_model(hosts[env['host']].get('model', 'unknown'))
    eligible = [e for e in envs if e.get('enabled', True) and e.get('pointer_ok') is True
                and (not host_only or e['kind'] == 'host') and (not serial or e['kind'] == 'tart')]
    if not eligible:
        raise ValueError('No eligible pointer-authorized environment; host execution refused')
    if serial or host_only:
        eligible = eligible[:1]
    jobs = {e['id']: [] for e in eligible}
    totals = {e['id']: 0 for e in eligible}
    durations = durations or {}
    measured = all(s in durations for s in scenarios)
    ordered = sorted(scenarios, key=lambda s: -durations[s]) if measured else scenarios
    for n, scenario in enumerate(ordered):
        chosen = min(totals, key=totals.get) if measured else eligible[n % len(eligible)]['id']
        jobs[chosen].append(scenario)
        totals[chosen] += durations.get(scenario, 1)
    return {'jobs': jobs, 'predicted_seconds': totals if measured else None,
            'assignment': 'longest-first' if measured else 'round-robin',
            'unit': 'test-method (four scenarios share VoiceBarFlowTests)',
            'excluded_hosts': [e['id'] for e in envs if e['kind'] == 'host' and not e.get('pointer_ok')]}


def build(host, root):
    repo = pathlib.Path(host['repo']).resolve()
    root = pathlib.Path(root)
    root.mkdir(parents=True, exist_ok=False)
    before = provenance(repo)
    verify_provenance({'build': {'provenance': before}})
    for name in ('ui-e2e-shard.py', 'ui-e2e-guest.py', 'ui_e2e_shard_io.py'):
        if HERE.with_name(name).read_bytes() != (repo / 'scripts' / name).read_bytes():
            raise ValueError('Worker bytes differ from the clean build checkout: ' + name)
    output = root / 'original'
    start = time.monotonic()
    with (root / 'build.log').open('w') as log:
        command([host['heavy'], 'ui-e2e-shard-build', 'env', 'VOICEBAR_UIE2E_GATE2245=1',
                 'VOICEBAR_UIE2E_GATE2246_CAPTURE=1', 'bash', str(repo / 'scripts/voicebar-ui-e2e.sh'),
                 '--scenario', 'focused-338', '--build-only', '--output', str(output)],
                cwd=repo, stdout=log, stderr=subprocess.STDOUT, timeout=BUILD_SECONDS)
    after = provenance(repo)
    if after != before:
        raise ValueError('Checkout changed during build')
    guard = load(repo / 'scripts/voicebar-ui-e2e-guard-proof.py', 'build_guard')
    guard.verify(repo, output)
    payload = root / 'payload'
    payload.mkdir()
    shutil.copytree(output, payload / 'output', symlinks=True)
    derived = pathlib.Path((output / 'derived-data-path.txt').read_text().strip())
    shutil.copytree(derived / 'Build/Products', payload / 'derived/Build/Products', symlinks=True)
    paths = list((repo / 'scripts').rglob('*'))
    paths += list((repo / 'flow-bar/Sources').rglob('*.swift'))
    paths += list((repo / 'flow-bar/UIE2E/VoiceBarUIE2ETests').glob('*.swift'))
    for source in paths:
        if source.is_symlink():
            continue
        if source.is_file() and source.suffix in ('.py', '.sh', '.swift', '.m'):
            target = payload / 'repo' / source.relative_to(repo)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
    for name in ['ui-e2e-shard.py', 'ui-e2e-guest.py', 'ui_e2e_shard_io.py']:
        shutil.copy2(HERE.with_name(name), payload / 'repo/scripts' / name)
    metadata = {'repo': str(repo), 'output': str(output), 'derived': str(derived),
                'root': str(root), 'seconds': time.monotonic() - start, 'provenance': before}
    (payload / 'origins.json').write_text(json.dumps(metadata, indent=2))
    (root / 'build-receipt.json').write_text(json.dumps(metadata, indent=2))
    return metadata


def relocate(payload, scenario):
    payload = pathlib.Path(payload).resolve()
    origins = json.loads((payload / 'origins.json').read_text())
    output = payload / 'output'
    mapping = sorted([(origins[k], str(payload / dest)) for k, dest in
                      [('repo', 'repo'), ('output', 'output'), ('derived', 'derived')]],
                     key=lambda pair: -len(pair[0]))
    def translate(value):
        if isinstance(value, str):
            for old, new in mapping:
                if value == old or value.startswith(old + '/'):
                    return new + value[len(old):]
        return value
    def tree(value):
        if isinstance(value, dict):
            return {k: tree(v) for k, v in value.items()}
        if isinstance(value, list):
            return [tree(v) for v in value]
        return translate(value)
    for runfile in (payload / 'derived/Build/Products').glob('*.xctestrun'):
        runfile.write_bytes(plistlib.dumps(tree(plistlib.loads(runfile.read_bytes()))))
    sandbox = pathlib.Path(translate((output / 'sandbox-path.txt').read_text().strip()))
    (output / 'sandbox-path.txt').write_text(str(sandbox) + '\n')
    (output / 'derived-data-path.txt').write_text(str(payload / 'derived') + '\n')
    (output / 'scenario.json').write_text(json.dumps({'scenario': scenario}))
    guard = load(payload / 'repo/scripts/voicebar-ui-e2e-guard-proof.py', 'relocated_guard')
    proof_path = output / 'device-guard-proof.json'
    proof = json.loads(proof_path.read_text())
    old_proof_hash = hashlib.sha256(proof_path.read_bytes()).hexdigest()
    expected = {translate(path): digest for path, digest in proof['identities'].items()}
    actual = guard.identities(payload / 'repo', output)
    # Only the location metadata changes; source, app, guard and test bytes must still match.
    location = str(output / 'derived-data-path.txt')
    if set(expected) != set(actual) or any(actual[p] != digest for p, digest in expected.items() if p != location):
        raise ValueError('Relocation changed protected build bytes')
    proof['identities'] = actual
    proof_path.write_text(json.dumps(proof, indent=2))
    (output / 'relocation.json').write_text(json.dumps({'originalProofSHA256': old_proof_hash,
                                                       'mapping': mapping}, indent=2))
    guard.verify(payload / 'repo', output)
    return output


def run_cases(payload, scenarios, guest=True):
    if guest:
        load(HERE.with_name('ui-e2e-guest.py'), 'guest_check').require_guest()
    else:
        pointer_model(command(['/usr/sbin/sysctl', '-n', 'hw.model'], stdout=subprocess.PIPE,
                              text=True).stdout.strip())
    payload = pathlib.Path(payload).resolve()
    results = []
    for scenario in scenarios:
        case = payload.parent / (scenario + '.noindex')
        # Guest APFS clone: preserve one built payload without duplicating all data blocks.
        command(['cp', '-cR', str(payload), str(case)], timeout=TRANSFER_SECONDS)
        output = relocate(case, scenario)
        started = time.monotonic()
        driver = 'ui-e2e-guest.py' if guest else 'voicebar-ui-e2e-supervisor.py'
        shell = ('set -euo pipefail; source "$1/repo/scripts/lib/output-mute-guard.sh"; '
                 'output_mute_guard_begin; python3 "$1/repo/scripts/$3" "$1/output" --scenario "$2"')
        with (output / 'guest-supervisor.log').open('w') as log:
            run = command(['bash', '-c', shell, 'ui-e2e-shard', str(case), scenario, driver],
                          stdout=log, stderr=subprocess.STDOUT, check=False,
                          timeout=SCENARIO_BUDGET_SECONDS[scenario] + CLEANUP_SECONDS)
        result = {'scenario': scenario, 'seconds': time.monotonic() - started, 'exit': run.returncode,
                  'xcresult': str(output / 'VoiceBar.xcresult'), 'output': str(output)}
        if not (output / 'VoiceBar.xcresult').is_dir():
            result.update(exit=1, error='Missing xcresult')
        results.append(result)
        (payload.parent / 'timings.json').write_text(json.dumps(results, indent=2))
        if result['exit']:
            break  # Stop the environment on permission, cleanup or test failure.
    return results


def environment(host, env, root, scenarios):
    if env.get('pointer_ok') is not True:
        raise ValueError('Environment lacks pointer authorization')
    if env['kind'] == 'host':
        native = str(pathlib.Path(root) / ('host-' + uuid.uuid4().hex + '.noindex') / 'payload')
        pathlib.Path(native).parent.mkdir()
        command(['cp', '-cR', str(pathlib.Path(root) / 'payload'), native], timeout=TRANSFER_SECONDS)
        start = time.monotonic()
        with (pathlib.Path(native).parent / 'native.log').open('w') as log:
            run = command([host['heavy'], 'ui-e2e-shard-native', sys.executable, str(HERE),
                           '_native', native, *scenarios], stdout=log, stderr=subprocess.STDOUT,
                          check=False, timeout=BUILD_SECONDS + case_budget(scenarios))
        results = pathlib.Path(native).parent / 'timings.json'
        return {'environment': env['id'], 'seconds': time.monotonic() - start,
                'exit': run.returncode, 'tests': json.loads(results.read_text()) if results.exists() else []}
    tart_env = dict(os.environ, TART_HOME=env['tart_home'], TART_NO_AUTO_PRUNE='1')
    ip = command(['/opt/homebrew/bin/tart', 'ip', env['vm']], env=tart_env,
                 stdout=subprocess.PIPE, text=True).stdout.strip()
    destination = env.get('user', 'admin') + '@' + ip
    guest = '/private/tmp/ui-shard-' + uuid.uuid4().hex + '.noindex'
    ssh(destination, ['mkdir', guest])
    payload = pathlib.Path(root) / 'payload'
    size = sum(p.stat().st_size for p in payload.rglob('*') if p.is_file())
    if shutil.disk_usage(root).free - size < DISK_FLOOR:
        raise RuntimeError('Payload transfer staging would cross the 15 GiB floor')
    # A bounded temporary stream avoids leaving a tar producer behind on failed SSH.
    with tempfile.TemporaryFile(dir=root) as archive:
        command(['tar', '-C', root, '-cf', '-', 'payload'], stdout=archive, timeout=TRANSFER_SECONDS)
        archive.seek(0)
        ssh(destination, ['tar', '-C', guest, '-xf', '-'], stdin=archive, timeout=TRANSFER_SECONDS)
    remote = guest + '/payload/repo/scripts/ui-e2e-shard.py'
    python = env.get('python', '/opt/homebrew/bin/python3')
    started = time.monotonic()
    errors = []
    run = None
    try:
        run = ssh(destination, ['env', 'DEVELOPER_DIR=' + env['developer_dir'],
                               'PATH=' + str(pathlib.PurePosixPath(python).parent) +
                               ':/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin',
                               python, remote, '_guest', guest + '/payload', *scenarios],
                  tty=True, stdin=subprocess.DEVNULL, check=False, stdout=subprocess.PIPE,
                  stderr=subprocess.PIPE, text=True, lease=[host['heavy'], 'ui-e2e-shard-' + env['id']],
                  timeout=BUILD_SECONDS + case_budget(scenarios) + CLEANUP_SECONDS)
    except Exception as error:
        errors.append({'error': str(error), 'stage': 'guest execution'})
    collect = pathlib.Path(root) / 'results' / uuid.uuid4().hex / env['id']
    collect.mkdir(parents=True, exist_ok=False)
    timings = []
    try:
        collect_remote(destination, guest + '/timings.json', collect / 'timings.json', python)
        timings = json.loads((collect / 'timings.json').read_text())
        for timing in timings:
            relative = guest_relative(timing['xcresult'], guest)
            timing['output'] = guest + '/' + str(relative.parent)
        errors.extend(collect_tests(destination, timings, collect, python))
    except Exception as error:
        errors.append({'error': str(error), 'stage': 'guest collection'})
    return {'environment': env['id'], 'seconds': time.monotonic() - started,
            'exit': run.returncode if run and not errors else 1, 'tests': timings,
            'artifacts': str(collect), 'collection_errors': errors,
            'stderr': run.stderr[-4000:] if run else ''}


def on_host(host, args):
    scenarios = json.loads(args[4]) if args[0] == '_env' else []
    timeout = (BUILD_SECONDS + case_budget(scenarios) + 4 * TRANSFER_SECONDS + CLEANUP_SECONDS
               if args[0] in ('_env', '_build') else 120)
    if not host.get('ssh'):
        return parse_result(command([sys.executable, str(HERE), *args], stdout=subprocess.PIPE,
                                    text=True, timeout=timeout).stdout)
    # Bootstrap uses no PTY (JSON may exceed terminal line limits). The worker gets its
    # own PTY in a separate call so cancellation/disconnection propagates HUP remotely.
    files = {name: HERE.with_name(name).read_text() for name in ['ui-e2e-shard.py', 'ui-e2e-guest.py', 'ui_e2e_shard_io.py']}
    digest = hashlib.sha256(json.dumps(files, sort_keys=True).encode()).hexdigest()[:16]
    bootstrap = ('import json,pathlib,sys; files=json.load(sys.stdin); '
                 'root=pathlib.Path.home()/".local/state/ui-e2e-shard-tools"/sys.argv[1]; '
                 'root.mkdir(parents=True,exist_ok=True); '
                 '[(root/n).write_text(v) for n,v in files.items()]; '
                 'print(' + repr(RESULT_MARKER) + '+json.dumps(str(root/"ui-e2e-shard.py")))')
    worker = parse_result(ssh(host['ssh'], ['python3', '-c', bootstrap, digest], input=json.dumps(files),
                             stdout=subprocess.PIPE, text=True).stdout)
    return parse_result(ssh(host['ssh'], ['python3', worker, *args], tty=True, stdin=subprocess.DEVNULL,
                            stdout=subprocess.PIPE, text=True, timeout=timeout).stdout)


def execute(config, assignment, output, reuse=None):
    hosts = {h['id']: h for h in config['hosts']}
    envs = {e['id']: e for e in config['environments']}
    active = {k: v for k, v in assignment['jobs'].items() if v}
    needed = {envs[k]['host'] for k in active}
    run_id = uuid.uuid4().hex
    roots = {k: str(pathlib.Path(hosts[k]['repo']) / '.build.noindex/ui-shards' / run_id) for k in needed}
    start = time.monotonic()
    execution_start = None
    build_receipts, results, errors = {}, [], []
    try:
        if reuse:
            saved = json.loads(pathlib.Path(reuse).read_text())
            build_receipts = {k: saved[k] for k in needed}
            for k in needed:
                current = on_host(hosts[k], ['_provenance', hosts[k]['repo']])
                verify_provenance({k: build_receipts[k]}, current)
            roots = {k: build_receipts[k]['root'] for k in needed}
        else:
            with concurrent.futures.ThreadPoolExecutor(max_workers=len(needed)) as pool:
                builds = {k: pool.submit(on_host, hosts[k], ['_build', json.dumps(hosts[k]), roots[k]]) for k in needed}
                for k, future in builds.items():
                    build_receipts[k] = future.result()
        verify_provenance(build_receipts)
        (output / 'builds.json').write_text(json.dumps(build_receipts, indent=2))
        execution_start = time.monotonic()
        with concurrent.futures.ThreadPoolExecutor(max_workers=len(active)) as pool:
            futures = {pool.submit(on_host, hosts[envs[k]['host']],
                                  ['_env', json.dumps(hosts[envs[k]['host']]), json.dumps(envs[k]),
                                   roots[envs[k]['host']], json.dumps(cases)]): k for k, cases in active.items()}
            for future in concurrent.futures.as_completed(futures):
                try:
                    results.append(future.result())
                except Exception as error:
                    results.append({'environment': futures[future], 'exit': 1, 'error': str(error)})
        for result in results:
            host = hosts[envs[result['environment']]['host']]
            if host.get('ssh'):
                result.setdefault('collection_errors', []).extend(
                    collect_tests(host['ssh'], result.get('tests', []), output / result['environment']))
        for k in needed:
            verify_provenance({k: build_receipts[k]}, on_host(hosts[k], ['_provenance', hosts[k]['repo']]))
    except Exception as error:
        errors.append(str(error))
    finally:
        tests = [t for r in results for t in r.get('tests', [])]
        expected = config.get('scenarios', list(SCENARIOS))
        passed = (not errors and not CANCELLED.is_set() and len(results) == len(active)
                  and sorted(t['scenario'] for t in tests) == sorted(expected)
                  and all(r['exit'] == 0 and not r.get('collection_errors') for r in results)
                  and all(t['exit'] == 0 for t in tests))
        summary = {'seconds_including_builds': time.monotonic() - start,
                   'execution_seconds': time.monotonic() - execution_start if execution_start else None,
                   'builds': build_receipts, 'environments': results, 'errors': errors,
                   'passed': passed, 'cancelled': CANCELLED.is_set(), 'assignment': assignment}
        (output / 'summary.json').write_text(json.dumps(summary, indent=2))
    return summary


def main():
    if len(sys.argv) > 1 and sys.argv[1].startswith('_'):
        action, *args = sys.argv[1:]
        if action == '_build':
            emit_result(build(json.loads(args[0]), args[1]))
        elif action == '_provenance':
            emit_result(provenance(args[0]))
        elif action == '_env':
            emit_result(environment(json.loads(args[0]), json.loads(args[1]), args[2], json.loads(args[3])))
        elif action == '_guest':
            emit_result(run_cases(args[0], args[1:]))
        elif action == '_native':
            emit_result(run_cases(args[0], args[1:], guest=False))
        else:
            raise ValueError('Unknown worker action')
        return
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('config', type=pathlib.Path)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    parser.add_argument('--execute', action='store_true')
    parser.add_argument('--serial-vm', action='store_true')
    parser.add_argument('--host-only', action='store_true')
    parser.add_argument('--durations', type=pathlib.Path)
    parser.add_argument('--reuse-builds', type=pathlib.Path)
    args = parser.parse_args()
    config = json.loads(args.config.read_text())
    durations = json.loads(args.durations.read_text()) if args.durations else None
    assignment = plan(config, durations, args.serial_vm, args.host_only)
    args.output.mkdir(parents=True, exist_ok=False)
    (args.output / 'plan.json').write_text(json.dumps(assignment, indent=2))
    if not args.execute:
        print(json.dumps(assignment, indent=2))
        return
    summary = execute(config, assignment, args.output, args.reuse_builds)
    summary['mode'] = 'serial-host' if args.host_only else 'serial-vm' if args.serial_vm else 'parallel'
    (args.output / 'summary.json').write_text(json.dumps(summary, indent=2))
    print(json.dumps(summary, indent=2))
    if not summary['passed']:
        raise SystemExit(1)


if __name__ == '__main__':
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, cancel_owned)
    main()
