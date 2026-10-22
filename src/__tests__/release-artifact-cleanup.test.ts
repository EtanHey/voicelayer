import { expect, test } from "bun:test";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
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

for (const mode of ["ordinary", "direct-noindex", "inode-swap", "after-open", "unsafe-python"] as const) {
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
version = base / 'artifacts.noindex'
if mode != 'direct-noindex':
    version /= 'version'
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
    assert mode in ('ordinary', 'direct-noindex', 'after-open'), 'unsafe cleanup was admitted'
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

test("release build refuses a version swap during swift without touching outside artifacts", () => {
  const runRoot = process.env.VOICELAYER_TEST_RUN_ROOT;
  if (!runRoot) throw new Error("Requires isolated preload");
  const base = realpathSync(mkdtempSync(join(runRoot, "build-race-")));
  try {
    const selected = join(base, "artifacts.noindex/version");
    const outside = join(base, "outside");
    mkdirSync(selected, { recursive: true });
    mkdirSync(join(outside, "VoiceBar.app"), { recursive: true });
    writeFileSync(join(outside, "VoiceBar.app/marker"), "keep");
    writeFileSync(join(outside, "VoiceBar.zip"), "keep zip");
    writeFileSync(join(base, "VoiceBar"), "fake binary");
    const hook = join(base, "hook.sh");
    writeFileSync(hook, `
swift() {
  if [[ "$*" == *--show-bin-path* ]]; then printf '%s\\n' "$TEST_BASE"; return; fi
  command mv "$TEST_SELECTED" "$TEST_SELECTED-held"
  command ln -s "$TEST_OUTSIDE" "$TEST_SELECTED"
  printf swapped > "$TEST_BASE/injected"
}
bash() { return 0; }
mkdir() { if [[ "$*" == *Contents/MacOS* ]]; then exit 77; fi; command mkdir "$@"; }
`);
    const result = Bun.spawnSync(["/bin/bash", "flow-bar/build-app.sh", "--install-path", join(selected, "VoiceBar.app"), "--no-stop", "--no-relaunch"], {
      cwd: repo, env: { ...process.env, BASH_ENV: hook, TEST_BASE: base,
        TEST_SELECTED: selected, TEST_OUTSIDE: outside,
        VOICEBAR_REQUIRE_NOTARIZATION: "1", VOICEBAR_RELEASE_ZIP: join(selected, "VoiceBar.zip") },
      stdout: "pipe", stderr: "pipe",
    });
    expect(existsSync(join(base, "injected"))).toBe(true);
    expect(existsSync(join(outside, "VoiceBar.app/marker"))).toBe(true);
    expect(readFileSync(join(outside, "VoiceBar.zip"), "utf8")).toBe("keep zip");
    expect(result.exitCode).not.toBe(0);
  } finally { rmSync(base, { recursive: true, force: true }); }
});

for (const mode of ["old-python", "applications-inode", "partial-delete", "publish", "publish-existing", "publish-existing-zip", "publish-swap"]) {
  test(`release helper contract: ${mode}`, () => {
    const runRoot = process.env.VOICELAYER_TEST_RUN_ROOT;
    if (!runRoot) throw new Error("Requires isolated preload");
    const base = realpathSync(mkdtempSync(join(runRoot, "release-contract-")));
    try {
      const result = Bun.spawnSync(["python3", "-c", `
import os, pathlib, runpy, shutil, subprocess, sys
base = pathlib.Path(sys.argv[2])
mode = sys.argv[3]
version = base / 'artifacts.noindex' / 'version'
version.mkdir(parents=True)
app = version / 'VoiceBar.app'
zip_path = version / 'VoiceBar.zip'
module = runpy.run_path(sys.argv[1])
if mode.startswith('publish'):
    builder = runpy.run_path(str(pathlib.Path(sys.argv[1]).with_name('build-release-artifacts.py')))
    outside = base / 'outside'
    outside.mkdir()
    (outside / 'VoiceBar.app').mkdir()
    (outside / 'VoiceBar.app' / 'marker').write_text('outside')
    (outside / 'VoiceBar.zip').write_text('outside zip')
    def fake_build(*args, **kwargs):
        pathlib.Path('VoiceBar.app').mkdir()
        pathlib.Path('VoiceBar.app/marker').write_text('built')
        pathlib.Path('VoiceBar.zip').write_text('zip')
        if mode == 'publish-swap':
            version.rename(version.with_name('held'))
            version.symlink_to(outside, target_is_directory=True)
        elif mode == 'publish-existing':
            app.mkdir()
        elif mode == 'publish-existing-zip':
            zip_path.write_text('existing zip')
    subprocess.run = fake_build
    try:
        builder['build'](str(app), str(zip_path), 'unused')
    except (OSError, ValueError):
        assert mode != 'publish'
    else:
        assert mode == 'publish'
        assert (app / 'marker').read_text() == 'built'
        assert zip_path.read_text() == 'zip'
    if mode == 'publish-existing':
        assert app.is_dir() and not list(app.iterdir())
    if mode == 'publish-existing-zip':
        assert zip_path.read_text() == 'existing zip'
    assert (outside / 'VoiceBar.app' / 'marker').read_text() == 'outside'
    assert (outside / 'VoiceBar.zip').read_text() == 'outside zip'
else:
    app.mkdir()
    (app / 'marker').write_text('keep')
    zip_path.write_text('keep zip')
    if mode == 'old-python':
        sys.version_info = (3, 9, 6)
        expected = 'Python 3.11 or newer'
    elif mode == 'applications-inode':
        real_stat = os.stat
        def fixture_stat(path, *args, **kwargs):
            return real_stat(version.parent if str(path) == '/Applications' else path, *args, **kwargs)
        os.stat = fixture_stat
        expected = 'must not be under /Applications'
    else:
        real_rmtree = shutil.rmtree
        def partial(path, *, dir_fd):
            child = os.open(path, os.O_RDONLY | os.O_DIRECTORY, dir_fd=dir_fd)
            try:
                os.unlink('marker', dir_fd=child)
            finally:
                os.close(child)
            raise PermissionError('fixture interruption')
        partial.avoids_symlink_attacks = True
        shutil.rmtree = partial
        expected = 'partially deleted, then failed'
    try:
        module['cleanup'](str(version), [str(app), str(zip_path)])
    except (ValueError, OSError) as error:
        assert expected in str(error), error
    else:
        raise AssertionError('unsafe operation admitted')
    assert zip_path.read_text() == 'keep zip'
    assert (app / 'marker').exists() == (mode != 'partial-delete')
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

test("release guard rejects the Applications firmlink alias by string only", () => {
  const result = Bun.spawnSync(["/bin/bash", "-c",
    'source scripts/lib/noindex-path.sh; require_release_artifact_path /System/Volumes/Data/Applications/example.noindex/version/VoiceBar.app'], {
    cwd: repo, env: process.env, stdout: "pipe", stderr: "pipe",
  });
  expect(result.exitCode).not.toBe(0);
  expect(result.stderr.toString()).toContain("must not be under /Applications");
});

test("release selects a supported Python when PATH contains an old interpreter", () => {
  const runRoot = process.env.VOICELAYER_TEST_RUN_ROOT;
  if (!runRoot) throw new Error("Requires isolated preload");
  const base = realpathSync(mkdtempSync(join(runRoot, "python-select-")));
  try {
    const python = join(base, "python3");
    writeFileSync(python, "#!/bin/sh\nexit 1\n");
    chmodSync(python, 0o755);
    const result = Bun.spawnSync(["/bin/bash", "-c",
      'source scripts/lib/noindex-path.sh; selected="$(release_artifact_python)" || exit; "$selected" -c "import sys; assert sys.version_info >= (3, 11)"'], {
      cwd: repo, env: { ...process.env, PATH: base }, stdout: "pipe", stderr: "pipe",
    });
    // A host without a known-good fallback must fail closed with an explanation.
    if (result.exitCode !== 0) {
      expect(result.stderr.toString()).toContain("require Python 3.11 or newer");
    } else {
      expect(result.stderr.toString()).toBe("");
    }
  } finally { rmSync(base, { recursive: true, force: true }); }
});
