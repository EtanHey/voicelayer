#!/usr/bin/env python3
"""Bounded transport, artifact collection and provenance for the UI shard runner."""
import json
import os
import pathlib
import shlex
import shutil
import signal
import subprocess
import tempfile
import threading
import time

SCENARIO_BUDGET_SECONDS = {'full': 2400, 'focused-338': 2400, 'hide1': 300, 'gate2246': 600}
CLEANUP_SECONDS = 240  # The supervised harness has a 180-second cleanup budget.
TRANSFER_SECONDS = 900
BUILD_SECONDS = 7200  # Includes the shared heavy queue; never remove its lock.
DISK_FLOOR = 15 * 1024 ** 3
POINTER_RIG_MODELS = frozenset({'MacBookPro18,3'})  # Captain-authorized M1 test rig.
SSH_OPTIONS = ['-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10',
               '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=3']
ACTIVE = set()
ACTIVE_LOCK = threading.RLock()
CANCELLED = threading.Event()
RESULT_MARKER = '__VOICEBAR_SHARD_RESULT__='


def emit_result(value):
    print(RESULT_MARKER + json.dumps(value), flush=True)


def parse_result(output):
    rows = [line[len(RESULT_MARKER):] for line in output.splitlines() if line.startswith(RESULT_MARKER)]
    if len(rows) != 1:
        raise ValueError('Expected exactly one marked worker result')
    return json.loads(rows[0])


def cancel_owned(number=signal.SIGTERM, frame=None):
    CANCELLED.set()
    with ACTIVE_LOCK:
        for process in ACTIVE:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass


def command(argv, timeout=120, check=True, **kwargs):
    """Bound every subprocess and reap only its owned session, including on cancellation."""
    if CANCELLED.is_set():
        raise InterruptedError('Shard run cancelled')
    data = kwargs.pop('input', None)
    input_file = None
    if data is not None:
        # Retrying communicate(None) after a timeout can strand an incompletely sent
        # pipe on macOS/Python. A seekable stdin remains valid through every retry.
        input_file = tempfile.TemporaryFile()
        input_file.write(data.encode(kwargs.get('encoding') or 'utf-8') if isinstance(data, str) else data)
        input_file.seek(0)
        kwargs['stdin'] = input_file
    try:
        process = subprocess.Popen(argv, start_new_session=True, **kwargs)
    except BaseException:
        if input_file:
            input_file.close()
        raise
    with ACTIVE_LOCK:
        ACTIVE.add(process)
    began = time.monotonic()
    try:
        while True:
            if CANCELLED.is_set() or time.monotonic() - began >= timeout:
                raise TimeoutError('cancelled' if CANCELLED.is_set() else 'deadline exceeded')
            try:
                stdout, stderr = process.communicate(timeout=max(.01, min(1, timeout - (time.monotonic() - began))))
                break
            except subprocess.TimeoutExpired:
                pass
        result = subprocess.CompletedProcess(argv, process.returncode, stdout, stderr)
        if CANCELLED.is_set():
            raise InterruptedError('Shard run cancelled')
        if check:
            result.check_returncode()
        return result
    except BaseException:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.communicate(timeout=CLEANUP_SECONDS)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate(timeout=10)
        raise
    finally:
        with ACTIVE_LOCK:
            ACTIVE.discard(process)
        if input_file:
            input_file.close()


def ssh(destination, argv, tty=False, lease=(), **kwargs):
    # Long workers have a controlling PTY: loss of SSH delivers HUP, which their handler
    # propagates to the separately owned supervisor sessions before exiting.
    return command([*lease, 'ssh', *SSH_OPTIONS, *(['-tt'] if tty else []), '--', destination,
                    shlex.join(list(map(str, argv)))], **kwargs)


def case_budget(scenarios):
    return sum(SCENARIO_BUDGET_SECONDS[s] + CLEANUP_SECONDS for s in scenarios)


def pointer_model(model):
    if not (model.startswith('VirtualMac') or model in POINTER_RIG_MODELS):
        raise ValueError('Pointer execution refused on non-allowlisted model: ' + model)


def provenance(repo):
    def git(*args):
        return command(['git', '-C', str(repo), *args], stdout=subprocess.PIPE, text=True).stdout.strip()
    return {'sha': git('rev-parse', 'HEAD'), 'status': git('status', '--porcelain=v1', '--untracked-files=normal')}


def verify_provenance(receipts, current=None):
    rows = [r.get('provenance', {}) for r in receipts.values()]
    if not rows or any(not r.get('sha') or r.get('status') != '' for r in rows):
        raise ValueError('Build provenance is absent or dirty')
    if len({r['sha'] for r in rows}) != 1:
        raise ValueError('Build source SHAs differ across hosts')
    if current is not None and current != rows[0]:
        raise ValueError('Reused build SHA/status differs from current checkout')


def guest_relative(path, root):
    # macOS canonicalizes /tmp to /private/tmp, including in resolved guest receipts.
    def canonical(value):
        value = str(value)
        if value == '/tmp' or value.startswith('/tmp/'):
            value = '/private' + value
        return pathlib.PurePosixPath(value)
    relative = canonical(path).relative_to(canonical(root))
    if '..' in relative.parts:
        raise ValueError('Guest artifact escaped owned run directory')
    return pathlib.Path(relative)


def collect_remote(destination, source, target, python='python3'):
    # Inspect only results, never the cloned payload or DerivedData/Build/Products.
    inspect = '''import pathlib,sys
p=pathlib.Path(sys.argv[1])
if not p.exists(): raise FileNotFoundError("missing artifact: "+str(p))
files=[p]+list(p.rglob("*")) if p.is_dir() else [p]
if p.is_symlink() or any(f.is_symlink() and not (f.resolve().is_file() and
        f.resolve().is_relative_to(p.resolve())) for f in files):
    raise ValueError("escaping/directory symlink refused")
print(sum(f.stat().st_size for f in files))'''
    size = int(ssh(destination, [python, '-c', inspect, source],
                   stdout=subprocess.PIPE, text=True).stdout)
    target = pathlib.Path(target)
    target.parent.mkdir(parents=True, exist_ok=True)
    if shutil.disk_usage(target.parent).free - size - 64 * 1024 ** 2 < DISK_FLOOR:
        raise RuntimeError('Artifact copy would cross the 15 GiB free-space floor')
    command(['scp', '-q', '-r', *SSH_OPTIONS, '--', destination + ':' + source, str(target)],
            timeout=TRANSFER_SECONDS)


def collect_tests(destination, tests, target, python='python3'):
    errors = []
    for test in tests:
        try:
            output = pathlib.Path(target) / (test['scenario'] + '.noindex') / 'output'
            collect_remote(destination, test['output'], output, python)
            test['output'] = str(output.resolve())
            test['xcresult'] = str(output.resolve() / 'VoiceBar.xcresult')
            if not pathlib.Path(test['xcresult']).is_dir():
                raise FileNotFoundError('Missing xcresult: ' + test['xcresult'])
            test['collected_xcresult'] = test['xcresult']
        except Exception as error:
            errors.append({'scenario': test.get('scenario'), 'error': str(error)})
    return errors
