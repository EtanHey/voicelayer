"""Verify committed local TLC evidence without Java, Bun, Swift, or network access."""
import argparse
import hashlib
import json
from pathlib import Path

from receipt_support import tracked_files, config_files


def verify(root):
    failures = []
    runners = sorted((root / 'formal').glob('*/check.sh'))
    if not runners:
        return ['formal: no model check.sh files found']
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
