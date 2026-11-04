"""Small exhaustive lifecycle proof; preserve expected failures and their traces."""
from pathlib import Path
import subprocess
import sys
import shutil
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tlc_support import tlc_jar

root = Path(__file__).resolve().parents[2]
output = root / '.build.noindex/clone-engine-tlc'
output.mkdir(parents=True, exist_ok=True)
jar = tlc_jar()
brew_java = Path('/opt/homebrew/opt/openjdk/bin/java')
java = str(brew_java) if brew_java.is_file() else shutil.which('java')
if not java:
    sys.exit('Java runtime not found; install a JDK before running TLC')
expected = {'Fixed': None, 'Old': 'Temporal property EventuallyRunningIfAutostart was violated', 'Mutant': 'Invariant AtMostOneEngine is violated'}
for name, failure in expected.items():
    result = subprocess.run([java, '-Xmx512m', '-XX:+UseParallelGC', '-cp', str(jar), 'tlc2.TLC',
        '-noGenerateSpecTE', '-workers', '1', '-metadir', str(output / name), '-config', f'formal/clone-engine/{name}.cfg',
        'formal/clone-engine/CloneEngine.tla'], cwd=root, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (output / f'{name}.log').write_text(result.stdout)
    okay = (result.returncode == 0 and 'No error has been found' in result.stdout) if failure is None else (result.returncode != 0 and failure in result.stdout)
    print(name, 'PASS' if okay else 'UNEXPECTED', 'exit', result.returncode)
    for line in result.stdout.splitlines():
        if any(s in line for s in ['states generated', 'distinct states', 'Error:', 'Finished in']): print(line)
    if not okay:
        print(result.stdout)
        sys.exit(1)
