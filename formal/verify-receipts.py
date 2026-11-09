"""Verify committed local TLC evidence without Java, Bun, Swift, or network access."""
import argparse
import ast
import hashlib
import json
from pathlib import Path
import re

from receipt_support import tracked_files, config_files


def workflow_trigger_paths(root):
    """Read both event filters without a YAML dependency.

    Accept the repo's quoted inline/block path lists and literal or directory/**
    patterns. Other YAML/glob syntax fails closed rather than guessing coverage.
    """
    lines = (root / '.github/workflows/formal.yml').read_text().splitlines()
    start = next((i for i, line in enumerate(lines) if line == 'on:'), None)
    if start is None:
        raise ValueError('missing on: trigger block')
    body = []
    for line in lines[start + 1:]:
        if line.strip() and not line.startswith(' '):
            break
        body.append(line)
    events = {}
    for event in ('push', 'pull_request'):
        start = next((i for i, line in enumerate(body) if line.strip() == event + ':' and line.startswith('  ') and not line.startswith('   ')), None)
        if start is None:
            raise ValueError(f'missing {event}.paths')
        block = []
        for line in body[start + 1:]:
            if line.strip() and len(line) - len(line.lstrip()) <= 2:
                break
            block.append(line)
        path_row = next((i for i, line in enumerate(block) if line.startswith('    paths:')), None)
        if path_row is None:
            raise ValueError(f'missing {event}.paths')
        value = block[path_row].split(':', 1)[1].strip()
        if value and not value.startswith('#'):
            paths = ast.literal_eval(value)
        else:
            paths = []
            for line in block[path_row + 1:]:
                if not line.strip() or line.lstrip().startswith('#'):
                    continue
                if not line.startswith('      - '):
                    break
                paths.append(ast.literal_eval(line.strip()[2:]))
        if not isinstance(paths, list) or not paths or not all(isinstance(p, str) and p for p in paths):
            raise ValueError(f'{event}.paths must be a nonempty quoted path list')
        for pattern in paths:
            literal = pattern[:-3] if pattern.endswith('/**') else pattern
            if not literal or pattern.startswith('!') or re.search(r'[*?+\[\]{}\\]', literal):
                raise ValueError(f'unsupported {event}.paths pattern: {pattern!r}')
        events[event] = paths
    return events


def triggered(path, patterns):
    return any(path.startswith(p[:-2]) if p.endswith('/**') else path == p for p in patterns)


def verify(root):
    failures = []
    try:
        triggers = workflow_trigger_paths(root)
    except (OSError, ValueError, SyntaxError) as exc:
        failures.append(f'.github/workflows/formal.yml: cannot verify trigger coverage: {exc}')
        triggers = {}
    runners = sorted((root / 'formal').glob('*/check.sh'))
    if not runners:
        return failures + ['formal: no model check.sh files found']
    pin = json.loads((root / 'formal/tlc.lock.json').read_text())['sha256']
    for runner in runners:
        directory = runner.parent
        errors = []
        try:
            receipt = json.loads((directory / 'results/run.json').read_text())
            manifest = json.loads((directory / 'checks.json').read_text())
            if receipt.get('complete') is not True:
                errors.append('results/run.json: incomplete receipt')
            if receipt.get('tlcJarSHA256') != pin:
                errors.append('results/run.json: TLC checksum differs from formal/tlc.lock.json')
            hashes = receipt['hashes']
            expected = {str(path.relative_to(root)) for path in tracked_files(directory, root, manifest)}
            for path in sorted(expected - hashes.keys()):
                errors.append(f'{path}: missing hash')
            for path, digest in sorted(hashes.items()):
                for event, patterns in triggers.items():
                    if not triggered(path, patterns):
                        errors.append(f'{path}: outside workflow {event}.paths; add trigger coverage')
                target = root / path
                if not target.resolve().is_relative_to(root.resolve()):
                    errors.append(f'{path}: hash path escapes repository')
                elif not target.is_file():
                    errors.append(f'{path}: missing file')
                elif hashlib.sha256(target.read_bytes()).hexdigest() != digest:
                    errors.append(f'{path}: stale hash')
            checks = receipt['checks']
            if set(checks) != set(manifest['checks']):
                errors.append('results/run.json: check inventory differs from checks.json')
            mutants = {target: [] for target in manifest['acceptance']}
            for name, check in manifest['checks'].items():
                row = checks.get(name, {})
                status = 'EXPECTED_FAIL' if check['target'] else 'PASS'
                if any(row.get(key) != check[key] for key in ('role', 'kind', 'target')) or row.get('status') != status:
                    errors.append(f'results/run.json: {name} must be {status} on {check["target"]}')
                if check['role'] == 'mutant':
                    mutants.setdefault(check['target'], []).append(name)
            if receipt.get('mutants') != mutants or not all(mutants.values()):
                errors.append('results/run.json: exact-property mutant coverage differs from checks.json')
            if set(config_files(directory, manifest)) != set(manifest['checks']):
                errors.append('checks.json: config inventory differs')
        except (OSError, ValueError, KeyError, TypeError, AttributeError) as exc:
            errors.append(str(exc).replace(str(root) + '/', ''))
        for error in errors:
            failures.append(f'{directory.name}: {error}\n  Re-record: python3 -B formal/check-model.py formal/{directory.name} --record')
    return failures


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    failures = verify(args.root.resolve())
    print('\n'.join(failures) if failures else 'PASS: all local TLC receipts match current inputs')
    return bool(failures)


if __name__ == '__main__':
    raise SystemExit(main())
