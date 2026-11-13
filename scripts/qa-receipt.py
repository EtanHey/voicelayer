#!/usr/bin/env python3
"""Private QA run receipts. No raw command, environment or output in metadata."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
import uuid

STATUSES = {'RUNNING', 'PASS', 'FAIL', 'INTERRUPTED', 'UNKNOWN', 'NOT_RUN', 'HOLD'}
FIELDS = {'schema', 'run', 'lane', 'head', 'host', 'status', 'started', 'finished',
          'pid', 'exit', 'evidence'}


def require(ok):
    if not ok:
        raise ValueError('invalid receipt or unsealed evidence')


def validate(data, root):
    """Strict v1 schema; local files must exist under private root and match seals."""
    require(isinstance(data, dict) and set(data) == FIELDS)
    require(type(data['schema']) is int and data['schema'] == 1)
    for key in ('run', 'lane', 'host'):
        require(isinstance(data[key], str) and
                re.fullmatch(r'[A-Za-z0-9_-]{1,64}', data[key]))
    require(isinstance(data['head'], str) and re.fullmatch(r'[a-f0-9]{40}', data['head']))
    require(data['status'] in STATUSES)
    require(type(data['pid']) is int and data['pid'] > 0)
    for key in ('started', 'finished'):
        if data[key] is not None:
            require(isinstance(data[key], str) and
                    re.fullmatch(r'\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\+00:00', data[key]))
            datetime.datetime.fromisoformat(data[key])
    require(data['started'] is not None)
    require((data['finished'] is None) == (data['status'] == 'RUNNING'))
    require(data['finished'] is None or data['finished'] >= data['started'])
    code = data['exit']
    require(code is None or type(code) is int)
    require(data['status'] != 'PASS' or code == 0)
    require(data['status'] != 'FAIL' or (code is not None and code != 0))
    require(data['status'] not in {'RUNNING', 'NOT_RUN', 'UNKNOWN', 'HOLD'} or code is None)
    require(isinstance(data['evidence'], list))
    for item in data['evidence']:
        require(isinstance(item, dict) and set(item) == {'path', 'sha256', 'visibility'})
        require(item['visibility'] == 'private')
        require(isinstance(item['path'], str) and
                re.fullmatch(r'[A-Za-z0-9_-]+\.(log|json|png|mp4|txt)', item['path']))
        require(isinstance(item['sha256'], str) and re.fullmatch(r'[a-f0-9]{64}', item['sha256']))
        path = root / item['path']
        require(not path.is_symlink() and path.is_file() and path.resolve().parent == root.resolve())
        require(hashlib.sha256(path.read_bytes()).hexdigest() == item['sha256'])
    return data


def write(root, data):
    validate(data, root)
    temporary = root / 'receipt.new'
    with temporary.open('w') as stream:
        json.dump(data, stream, indent=2)
        stream.write('\n')
    temporary.replace(root / 'receipt.json')


def now():
    return datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat()


def run(lane, command):
    require(re.fullmatch(r'L[0-9]+', lane) and command)
    # Fixed outside-repository store; no output-path override or inherited XDG path.
    base = Path.home() / '.local/state/voicelayer/qa-receipts'
    base.mkdir(parents=True, exist_ok=True, mode=0o700)
    require(not any(p.is_symlink() for p in (base, *base.parents)))
    root = base / uuid.uuid4().hex
    root.mkdir(mode=0o700)
    head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
    data = dict(schema=1, run=root.name, lane=lane, head=head,
                host=hashlib.sha256(socket.gethostname().encode()).hexdigest()[:16],
                status='RUNNING', started=now(), finished=None, pid=os.getpid(),
                exit=None, evidence=[])
    write(root, data)
    print(root / 'receipt.json', flush=True)
    code = None
    try:
        with (root / 'output.log').open('wb') as output:
            code = subprocess.call(command, stdout=output, stderr=subprocess.STDOUT)
        data['status'] = 'PASS' if code == 0 else 'FAIL'
    except KeyboardInterrupt:
        data['status'] = 'INTERRUPTED'
        code = 130
    except OSError:
        data['status'] = 'FAIL'
        code = 127
    finally:
        data.update(exit=code, finished=now())
        output = root / 'output.log'
        if output.exists() and output.stat().st_size:
            data['evidence'] = [dict(path=output.name, visibility='private',
                                     sha256=hashlib.sha256(output.read_bytes()).hexdigest())]
        elif output.exists():
            output.unlink()  # Only this run's own empty log, never historical artifacts.
        write(root, data)
    return code if code is not None and code >= 0 else 1


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='action', required=True)
    check = sub.add_parser('validate')
    check.add_argument('receipt', type=Path)
    execute = sub.add_parser('run')
    execute.add_argument('--lane', required=True)
    execute.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.action == 'run':
        command = args.command[1:] if args.command[:1] == ['--'] else args.command
        return run(args.lane, command)
    validate(json.loads(args.receipt.read_text()), args.receipt.parent)
    print('VALID (private receipt; no publication approval)')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, TypeError, KeyError, OSError):
        print('INVALID receipt or invocation (details withheld)', file=sys.stderr)
        sys.exit(1)
