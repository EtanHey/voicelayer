"""Reuse successful SHA-pinned BASE rows; never cache failed or incomplete runs."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
if os.environ.get('RATCHET_BASE_HARNESS'):
    sys.path.insert(0, os.environ['RATCHET_BASE_HARNESS'])
from run import ROWS, sha
import run as harness


def cacheable(item, row, base):
    return (isinstance(item, dict) and item.get('row') == row
            and item.get('measured_sha') == base and item.get('error') is None
            and item.get('status') == 'PASS' and type(item.get('value')) is int
            and item['value'] == 0 and item.get('kind') == 'behavior'
            and type(item.get('ceiling')) is int and item['ceiling'] == 0
            and item.get('bug_sha') == sha(ROWS[row][0])
            and item.get('fix_sha') == sha(ROWS[row][1])
            and isinstance(item.get('app_binary_sha256'), str)
            and len(item['app_binary_sha256']) == 64
            and (row not in ('socket-isolation', 'recents-newest-after-retranscribe')
                 or isinstance(item.get('overlay_sha256'), str)
                 and len(item['overlay_sha256']) == 64))


def load(path):
    try:
        data = json.loads(path.read_text())
        return data if isinstance(data, list) else []
    except (OSError, ValueError):
        return []


def baseline(base, cached, output, execute=None):
    output.mkdir(parents=True, exist_ok=True)
    execute = execute or subprocess.run
    candidates = load(cached / 'result.json')
    results, failed = [], False
    for row in ROWS:
        row_candidates = load(cached / row / 'result.json') or candidates
        matches = [item for item in row_candidates if isinstance(item, dict) and item.get('row') == row]
        if len(matches) == 1 and cacheable(matches[0], row, base):
            result = dict(matches[0], baseline_source='cached')
            print('Cached BASE: ' + row, flush=True)
        else:
            destination = output / row
            if destination.exists():
                raise RuntimeError('Refusing stale BASE output directory: ' + str(destination))
            destination.mkdir()
            completed = execute([sys.executable, str(Path(harness.__file__).resolve()),
                                 '--ref', base, '--row', row, '--output', str(destination)])
            fresh = load(destination / 'result.json')
            if len(fresh) != 1 or not isinstance(fresh[0], dict) or fresh[0].get('row') != row:
                fresh = [dict(row=row, measured_sha=base, bug_sha=sha(ROWS[row][0]),
                              fix_sha=sha(ROWS[row][1]), kind='behavior', ceiling=0,
                              value=1, status='FAIL', error='no result')]
            result = dict(fresh[0], baseline_source='measured',
                          baseline_run_id=os.environ.get('GITHUB_RUN_ID'))
            failed |= completed.returncode != 0
        result['baseline_receipt'] = 'baseline ' + result['baseline_source'] + ' @' + base
        print(row + ': ' + result['baseline_receipt'], flush=True)
        results.append(result)
        (output / 'result.json').write_text(json.dumps(results, indent=2) + '\n')
        if cacheable(result, row, base) and not (result['baseline_source'] == 'measured' and completed.returncode):
            saved = output / 'cache' / row
            saved.mkdir(parents=True, exist_ok=True)
            (saved / 'result.json').write_text(json.dumps([result], indent=2) + '\n')
    (output / 'result.json').write_text(json.dumps(results, indent=2) + '\n')
    clean = all(cacheable(item, row, base) for row, item in zip(ROWS, results)) and not failed
    return results, clean


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--ref', required=True)
    parser.add_argument('--cached', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    results, clean = baseline(sha(args.ref), args.cached, args.output)
    # BASE failures are reported, never the PR-head gate or a red main check.
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
