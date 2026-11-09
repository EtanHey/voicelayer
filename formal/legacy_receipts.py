"""Record standard receipts around preserved legacy TLC and conformance runners.

A receipt is emitted only after the entire original runner succeeds. In particular,
speech-queue retains its cross-kill matrix and real Swift/daemon replays.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

from receipt_support import tracked_files
from tlc_support import tlc_jar


def record(directory, root, cache, manifest, write):
    digest = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
    hashes = {str(p.relative_to(root)): digest(p) for p in tracked_files(directory, root, manifest)}
    jar_hash = digest(tlc_jar())
    (cache / 'run.json').unlink(missing_ok=True)
    command = ['bash', str(directory / 'check.sh')]
    if directory.name == 'history-row-refresh':
        logs = Path(tempfile.mkdtemp(prefix='legacy-', dir=cache))
        command.append(str(logs))
    output = cache / 'legacy-runner.log'
    with output.open('w') as saved:
        child = subprocess.Popen(command, cwd=root, env=os.environ, stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT, text=True)
        for line in child.stdout:
            saved.write(line)
            saved.flush()
            print(line, end='', flush=True)
        code = child.wait()
    if code:
        raise SystemExit(f'{directory.name}: original runner failed ({code}); no receipt written. See {output}')
    text = output.read_text()
    if directory.name != 'history-row-refresh':
        markers = re.findall(r'^(?:logs:|Run output:|Evidence:) (.+)$', text, re.M)
        if len(markers) != 1:
            raise SystemExit(f'{directory.name}: missing unambiguous runner log directory')
        logs = Path(markers[0]).resolve()
    rows = {}
    for name, check in manifest['checks'].items():
        log_path = logs / f'{name}.log'
        if not log_path.exists():
            log_path = logs / f'{name}.cfg.log'
        log = log_path.read_text()
        counts = re.findall(r'([\d,]+) states generated, ([\d,]+) distinct states found', log)
        # TLC initial-state violations legitimately have no state-count summary.
        if not counts and 'violated by the initial state:' not in log:
            raise SystemExit(f'{name}: missing completed state counts')
        generated, distinct = [int(v.replace(',', '')) for v in counts[-1]] if counts else (None, None)
        rows[name] = dict(role=check['role'], kind=check['kind'], target=check['target'],
                          status='EXPECTED_FAIL' if check['target'] else 'PASS',
                          generated=generated, distinct=distinct)
    assert all(digest(root / p) == sha for p, sha in hashes.items()), 'Inputs changed during legacy run'
    assert digest(tlc_jar()) == jar_hash, 'TLC changed during legacy run'
    mutants = {target: [] for target in manifest['acceptance']}
    for name, check in manifest['checks'].items():
        if check['role'] == 'mutant':
            mutants[check['target']].append(name)
    assert all(mutants.values()), 'Every property needs its existing exact-property negative control'
    receipt = dict(complete=True, tlcJarSHA256=jar_hash, hashes=hashes, mutants=mutants,
                   graphHashes={p.stem: digest(p) for p in sorted(logs.glob('*.dot'))}, checks=rows)
    (cache / 'run.json').write_text(json.dumps(receipt, indent=2) + '\n')
    if write:
        evidence = directory / 'results'
        evidence.mkdir(exist_ok=True)
        (evidence / 'run.json').write_text(json.dumps(receipt, indent=2) + '\n')
        for name, row in rows.items():
            (evidence / f'{name}.log').write_text(json.dumps(row, indent=2) + '\n')
    print(f'{directory.name}: complete receipt ({len(rows)} unchanged checks)', flush=True)
