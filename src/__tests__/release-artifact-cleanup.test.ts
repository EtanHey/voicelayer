import { expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";

const repo = resolve(import.meta.dir, "../..");
const version: string = JSON.parse(readFileSync(join(repo, "package.json"), "utf8")).version;

test("release refuses a version-directory symlink swap between validation and deletion", () => {
  const runRoot = process.env.VOICELAYER_TEST_RUN_ROOT;
  if (!runRoot) throw new Error("Release cleanup fixtures require the isolated preload");
  const base = realpathSync(mkdtempSync(join(runRoot, "cleanup-race-")));
  try {
    const root = join(base, "artifacts.noindex");
    const selected = join(root, version);
    const outside = join(base, "outside");
    for (const dir of [selected, outside]) {
      mkdirSync(join(dir, "VoiceBar.app"), { recursive: true });
      writeFileSync(join(dir, "VoiceBar.app/marker"), "preserve app");
      writeFileSync(join(dir, "VoiceBar.zip"), "preserve zip");
    }
    const hook = join(base, "swap.py");
    const injected = join(root, "injected");
    const trace = join(root, "operations");
    writeFileSync(hook, `import os, pathlib
selected = pathlib.Path(os.environ["NOINDEX1B_SELECTED"])
selected.rename(selected.with_name(selected.name + "-validated"))
selected.symlink_to(os.environ["NOINDEX1B_OUTSIDE"], target_is_directory=True)
pathlib.Path(os.environ["NOINDEX1B_INJECTED"]).write_text("swapped")
`);
    const shellEnv = join(base, "intercept.sh");
    writeFileSync(shellEnv, `
mkdir() { command python3 "$NOINDEX1B_TEST_BEFORE_DELETE"; }
rm() {
  command rm "$@"
  printf 'rm\\n' >> "$NOINDEX1B_TRACE"
}
bash() { printf 'build\\n' >> "$NOINDEX1B_TRACE"; return 73; }
`);
    const result = Bun.spawnSync(["/bin/bash", "scripts/release-voicebar.sh", "--output-dir", root, "--skip-tap-check"], {
      cwd: repo,
      env: { ...process.env, BASH_ENV: shellEnv, NOINDEX1B_TEST_BEFORE_DELETE: hook,
        NOINDEX1B_SELECTED: selected, NOINDEX1B_OUTSIDE: outside, NOINDEX1B_INJECTED: injected, NOINDEX1B_TRACE: trace },
      stdout: "pipe", stderr: "pipe",
    });
    expect(existsSync(injected)).toBe(true);
    expect(readFileSync(join(outside, "VoiceBar.app/marker"), "utf8")).toBe("preserve app");
    expect(readFileSync(join(outside, "VoiceBar.zip"), "utf8")).toBe("preserve zip");
    expect(result.exitCode).toBe(1);
    expect(result.stderr.toString()).toContain("ERROR:");
    expect(existsSync(trace)).toBe(false);
  } finally { rmSync(base, { recursive: true, force: true }); }
});

for (const mode of ["ordinary", "inode-swap", "after-open", "unsafe-python"] as const) {
  test(`descriptor cleanup: ${mode}`, () => {
    const runRoot = process.env.VOICELAYER_TEST_RUN_ROOT;
    if (!runRoot) throw new Error("Release cleanup fixtures require the isolated preload");
    const base = realpathSync(mkdtempSync(join(runRoot, "cleanup-fd-")));
    try {
      const result = Bun.spawnSync(["python3", "-c", `
import os, pathlib, runpy, shutil, sys
module = runpy.run_path(sys.argv[1])
base = pathlib.Path(sys.argv[2])
mode = sys.argv[3]
version = base / 'artifacts.noindex' / 'version'
outside = base / 'outside'
for directory in (version, outside):
    (directory / 'VoiceBar.app').mkdir(parents=True)
    (directory / 'VoiceBar.app' / 'marker').write_text('keep')
    (directory / 'VoiceBar.zip').write_text('keep zip')
(version / 'unrelated').write_text('keep unrelated')
# Recursive cleanup must unlink this entry without traversing its target.
(version / 'VoiceBar.app' / 'external').symlink_to(outside, target_is_directory=True)
real_open = os.open
swapped = False
def injected_open(name, flags, *args, **kwargs):
    global swapped
    if name == 'version' and not swapped and mode in ('inode-swap', 'after-open'):
        swapped = True
        if mode == 'after-open':
            fd = real_open(name, flags, *args, **kwargs)
        version.rename(version.with_name('validated'))
        if mode == 'inode-swap':
            version.mkdir()
        else:
            version.symlink_to(outside, target_is_directory=True)
            return fd
    return real_open(name, flags, *args, **kwargs)
os.open = injected_open
if mode == 'unsafe-python':
    shutil._use_fd_functions = False
try:
    module['cleanup'](str(version), [str(version / 'VoiceBar.app'), str(version / 'VoiceBar.zip')])
except ValueError as error:
    assert mode in ('inode-swap', 'unsafe-python'), error
    assert ('changed during validation' if mode == 'inode-swap' else 'lacks symlink-safe') in str(error)
else:
    assert mode in ('ordinary', 'after-open'), 'unsafe cleanup was admitted'
    cleaned = version.with_name('validated') if swapped else version
    assert not (cleaned / 'VoiceBar.app').exists()
    assert not (cleaned / 'VoiceBar.zip').exists()
    assert (cleaned / 'unrelated').read_text() == 'keep unrelated'
assert (outside / 'VoiceBar.app' / 'marker').read_text() == 'keep'
assert (outside / 'VoiceBar.zip').read_text() == 'keep zip'
if mode in ('inode-swap', 'unsafe-python'):
    preserved = version.with_name('validated') if swapped else version
    assert (preserved / 'VoiceBar.app' / 'marker').read_text() == 'keep'
    assert (preserved / 'VoiceBar.zip').read_text() == 'keep zip'
print('verified')
`, join(repo, "scripts/lib/cleanup-release-artifacts.py"), base, mode], {
        cwd: repo, env: process.env, stdout: "pipe", stderr: "pipe",
      });
      expect(result.stderr.toString()).toBe("");
      expect(result.exitCode).toBe(0);
      expect(result.stdout.toString().trim()).toBe("verified");
    } finally { rmSync(base, { recursive: true, force: true }); }
  });
}
