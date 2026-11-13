#!/usr/bin/env python3
"""Export only the original fold; never bless current apply() as the oracle."""
import pathlib, subprocess
root = pathlib.Path(__file__).resolve().parents[2]
crate = root / 'rune-bar'
scratch = root / '.build.noindex' / 'golden-61d019d2'
scratch.mkdir(parents=True, exist_ok=True)
baseline = subprocess.check_output(['git', 'show', '61d019d2:rune-bar/src/band.rs'], cwd=root)
(scratch / 'band.rs').write_bytes(baseline)
runner = crate / 'tests' / 'golden_baseline.rs'
assert not runner.exists()
runner.write_text(f'#[path = "{scratch / "band.rs"}"] mod baseline;\nuse baseline::*;\n' + '''include!("support/golden_dump.rs");
#[test]
fn generate() {
    for name in REPLAYS { for reduced in [false,true] {
        let hash = dump(name,reduced,|s,t| s.sample(t));
        println!("GOLDEN {hash}  {name} reduced={reduced}");
    }}
}
''')
try:
    result = subprocess.run(['cargo','test','--locked','--test','golden_baseline','--','--nocapture'], cwd=crate, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    print(result.stdout)
    result.check_returncode()
    lines = [line.removeprefix('GOLDEN ') for line in result.stdout.splitlines() if line.startswith('GOLDEN ')]
    assert len(lines) == 14
    (crate / 'docs/replays/band-golden.sha256').write_text('\n'.join(lines)+'\n')
finally:
    runner.unlink()
