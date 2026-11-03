#!/usr/bin/env python3
"""Check fixed models and require a specific counterexample for every property mutant."""
import hashlib
import json
import os
import re
import signal
import subprocess
import tempfile
from pathlib import Path
from tlc_result import valid_result

root = Path(__file__).resolve().parent
scratch = root.parent.parent / '.build.noindex' / 'tlc-lane-d'
scratch.mkdir(parents=True, exist_ok=True)
logs = Path(tempfile.mkdtemp(prefix='run-', dir=scratch))
source_jar = Path.home() / '.cache/tla/tla2tools.jar'
# Freeze the bytes used by every Java child even if the shared cache changes.
jar = logs / 'tla2tools.jar'
jar_bytes = source_jar.read_bytes()
jar.write_bytes(jar_bytes)
jar_sha = hashlib.sha256(jar_bytes).hexdigest()
help_result = subprocess.run(['java', '-cp', str(jar), 'tlc2.TLC', '-help'],
                             env=os.environ.copy(), capture_output=True, text=True, timeout=10)
version = re.search(r'\bVersion ([^\r\n]+)', help_result.stdout + help_result.stderr)
if help_result.returncode not in (0, 1) or not version:
    raise RuntimeError('Cannot identify the TLC jar version')
identity = {'version': version.group(1), 'sha256': jar_sha, 'source': str(source_jar)}
(logs / 'jar.json').write_text(json.dumps(identity, indent=2) + '\n')
print(f'TLC jar: Version {identity["version"]}; sha256={jar_sha}; source={source_jar}', flush=True)
print(f'Run output: {logs}', flush=True)
manifest = json.loads((root / 'mutants.json').read_text())
rows = []
required = set()
for config in root.glob('Fixed*.cfg'):
    required.update(re.findall(r'^(?:INVARIANT|PROPERTY) (\w+)$', config.read_text(), re.M))
missing = required - {mutant['property'] for mutant in manifest}
if missing:
    raise RuntimeError(f'Properties without mutants: {sorted(missing)}')

def run(directory, module, config, label, expected=None):
    path = logs / (label + '.log')
    with path.open('w') as output:
        child = subprocess.Popen(['java', '-Xmx512m', '-XX:+UseParallelGC', '-cp', str(jar), 'tlc2.TLC',
                                  '-workers', '1', '-metadir', str(directory / (label + '-states')),
                                  '-config', str(config), module],
                                 cwd=directory, env=os.environ.copy(), stdout=output,
                                 stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = child.wait(timeout=30)
        except subprocess.TimeoutExpired:
            code = 124
        finally:
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            child.wait()
    text = path.read_text()
    path.write_text(text.replace(str(directory), '<model-check>').replace(str(root), '<formal-root>'))
    valid = valid_result(code, text, expected, Path(config).read_text())
    states = re.search(r'(\d+) states generated, (\d+) distinct states found', text)
    rows.append((label, expected or 'fixed', code, states.group(2) if states else '-', bool(valid)))
    print(f'{label}: exit={code} expected={expected or "PASS"} valid={bool(valid)}', flush=True)
    return bool(valid)

success = True
with tempfile.TemporaryDirectory(prefix='check-', dir=scratch) as temporary:
    directory = Path(temporary)
    for module in ['ResidentRecognizer.tla', 'RuntimeSetup.tla', 'ArchiveGateEvidence.tla', 'MemoryPressure.tla']:
        (directory / module).write_text((root / module).read_text())
    for config in ['Fixed.cfg', 'FixedAssetsGate.cfg', 'FixedDelete.cfg', 'FixedDownload.cfg',
                   'FixedReadyReselect.cfg', 'FixedSetupCancel.cfg', 'FixedArchiveGate.cfg', 'FixedMemoryPressure.cfg']:
        module = ('MemoryPressure.tla' if 'MemoryPressure' in config else
                  'ArchiveGateEvidence.tla' if 'ArchiveGate' in config else
                  'RuntimeSetup.tla' if 'Setup' in config else 'ResidentRecognizer.tla')
        success = run(directory, module, root / config, config[:-4]) and success
    for mutant in manifest:
        module = mutant['module']
        text = (root / module).read_text()
        for before, after in mutant.get('replace', []):
            if text.count(before) != 1:
                raise RuntimeError(f'{mutant["name"]}: mutation must match exactly once: {before!r}')
            text = text.replace(before, after, 1)
        (directory / module).write_text(text)
        success = run(directory, module, root / 'mutants' / (mutant['name'] + '.cfg'),
                      mutant['name'], mutant['property']) and success
        (directory / module).write_text((root / module).read_text())
summary = '| Run | Target | Exit | Distinct states | Accepted |\n| --- | --- | --- | --- | --- |\n'
summary += ''.join(f'| {name} | {prop} | {code} | {states} | {valid} |\n' for name, prop, code, states, valid in rows)
(logs / 'SUMMARY.md').write_text(summary)
raise SystemExit(0 if success else 1)
