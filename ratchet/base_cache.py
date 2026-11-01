"""Reuse successful SHA-pinned BASE rows; never cache failed or incomplete runs."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
from run import ROWS, sha


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
        matches = [item for item in candidates if isinstance(item, dict) and item.get('row') == row]
        if len(matches) == 1 and cacheable(matches[0], row, base):
            result = matches[0]
            print('Cached BASE: ' + row, flush=True)
        else:
            destination = output / row
            destination.mkdir()  # Refuse stale output from a previous attempt.
            completed = execute([sys.executable, str(Path(__file__).with_name('run.py')),
                                 '--ref', base, '--row', row, '--output', str(destination)])
            fresh = load(destination / 'result.json')
            if len(fresh) != 1 or not isinstance(fresh[0], dict) or fresh[0].get('row') != row:
                raise RuntimeError('BASE row did not produce a result: ' + row)
            result = fresh[0]
            failed |= completed.returncode != 0
        results.append(result)
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
    if clean:
        (args.output / 'cacheable').touch()
    return int(any(item['status'] != 'PASS' for item in results))


if __name__ == '__main__':
    raise SystemExit(main())
