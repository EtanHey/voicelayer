import { expect, test } from "bun:test";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { join, relative, resolve } from "node:path";

const root = resolve(import.meta.dir, "../..");
const version: string = JSON.parse(readFileSync(join(root, "package.json"), "utf8")).version;

function withReleaseFixture(check: (fixture: ReturnType<typeof releaseFixture>) => void) {
  const fixture = releaseFixture();
  try { check(fixture); }
  finally { rmSync(fixture.base, { recursive: true, force: true }); }
}

function releaseFixture() {
  const runRoot = process.env.VOICELAYER_TEST_RUN_ROOT;
  if (!runRoot) throw new Error("Release fixtures require the isolated test preload");
  const base = realpathSync(mkdtempSync(join(runRoot, "release-guard-")));
  const applications = join(base, "Applications.noindex");
  mkdirSync(applications);
  writeFileSync(join(base, "sitecustomize.py"), `import os
real_stat = os.stat
def fixture_stat(path, *args, **kwargs):
    return real_stat(os.environ["TEST_APPLICATIONS"] if str(path) == '/Applications' else path, *args, **kwargs)
os.stat = fixture_stat
`);
  const safe = join(base, "artifacts.noindex");
  const versionDir = join(safe, version);
  const trace = join(base, "operations.log");
  const shellEnv = join(base, "intercept.sh");
  mkdirSync(safe);
  // Observe admission to cleanup without executing mkdir/rm or any build.
  // In particular, /Applications arguments are only logged, never acted on.
  writeFileSync(shellEnv, `
record_operation() {
  printf '%s' "$1" >> "$NOINDEX1B_TRACE"
  shift
  printf '\\t%s' "$@" >> "$NOINDEX1B_TRACE"
  printf '\\n' >> "$NOINDEX1B_TRACE"
}
mkdir() { record_operation mkdir "$@"; }
rm() { record_operation rm "$@"; }
bash() { record_operation build "$@"; return 73; }
`);
  const bin = join(base, "bin");
  mkdirSync(bin);
  const realPython = Bun.which("python3");
  if (!realPython) throw new Error("Python required for guard fixtures");
  const python = join(bin, "python3");
  writeFileSync(python, `#!/bin/bash
if [[ "$1" == */cleanup-release-artifacts.py ]]; then
  shift
  printf 'cleanup' >> "$NOINDEX1B_TRACE"
  printf '\\t%s' "$@" >> "$NOINDEX1B_TRACE"
  printf '\\n' >> "$NOINDEX1B_TRACE"
else
  exec "${realPython}" "$@"
fi
`);
  chmodSync(python, 0o755);
  const markers = new Map<string, string>();
  const keep = (path: string) => {
    mkdirSync(resolve(path, ".."), { recursive: true });
    const content = `preserve ${path}`;
    writeFileSync(path, content);
    markers.set(path, content);
  };
  const run = (output = safe) => {
    const result = Bun.spawnSync(["/bin/bash", "scripts/release-voicebar.sh", "--output-dir", output, "--skip-tap-check"], {
      cwd: root, env: { ...process.env, BASH_ENV: shellEnv, PYTHONPATH: base, TEST_APPLICATIONS: applications, NOINDEX1B_TRACE: trace, PATH: `${bin}:${process.env.PATH}` },
      stdout: "pipe", stderr: "pipe",
    });
    for (const [path, content] of markers) expect(readFileSync(path, "utf8")).toBe(content);
    return { ...result, operations: existsSync(trace) ? readFileSync(trace, "utf8") : "" };
  };
  return { base, applications, safe, versionDir, keep, run };
}

for (const output of ["/Applications/NOINDEX1B-synthetic", "/Applications/NOINDEX1B-synthetic.noindex"]) {
  test(`release rejects artifact root ${output} before mkdir or cleanup`, () => withReleaseFixture(f => {
    const result = f.run(output);
    expect(result.operations).toBe("");
    expect(result.exitCode).toBe(1);
    expect(result.stderr.toString()).toContain("ERROR:");
  }));
}

for (const applicationsRoot of ["/applications", "/aPpLiCaTiOnS"]) {
  test(`release rejects case-alias artifact root ${applicationsRoot} before mkdir or cleanup`, () => withReleaseFixture(f => {
    const result = f.run(join(applicationsRoot, "NOINDEX1B-synthetic.noindex"));
    expect(result.operations).toBe("");
    expect(result.exitCode).toBe(1);
    expect(result.stderr.toString()).toContain("release artifacts must not be under /Applications");
  }));

  for (const entry of ["version", "app", "zip"]) {
    test(`release rejects ${entry} symlink into ${applicationsRoot}/*.noindex before mkdir or cleanup`, () => withReleaseFixture(f => {
      const name = entry === "app" ? "VoiceBar.app" : entry === "zip" ? "VoiceBar.zip" : version;
      const target = join(f.applications, applicationsRoot.slice(1), "NOINDEX1B-synthetic.noindex", name);
      if (entry === "version") {
        symlinkSync(target, f.versionDir);
      } else {
        mkdirSync(f.versionDir);
        symlinkSync(target, join(f.versionDir, name));
        f.keep(join(f.versionDir, entry === "app" ? "VoiceBar.zip" : "VoiceBar.app/marker"));
      }
      const result = f.run();
      expect(result.operations).toBe("");
      expect(result.exitCode).toBe(1);
      expect(result.stderr.toString()).toContain("release artifacts must not be under /Applications");
    }));
  }
}

for (const entry of ["version", "app", "zip"] as const) {
  for (const destination of ["indexed", "applications", "applications-noindex"] as const) {
    test(`release rejects ${entry} symlink into ${destination} before mkdir or cleanup`, () => withReleaseFixture(f => {
      const name = entry === "app" ? "VoiceBar.app" : entry === "zip" ? "VoiceBar.zip" : version;
      const target = destination === "indexed" ? join(f.base, "indexed", name)
        : join(f.applications, `NOINDEX1B-synthetic${destination === "applications-noindex" ? ".noindex" : ""}`, name);
      if (destination === "indexed") {
        f.keep(entry === "zip" ? target : join(target, "marker"));
      }
      if (entry === "version") {
        symlinkSync(target, f.versionDir);
      } else {
        mkdirSync(f.versionDir);
        symlinkSync(target, join(f.versionDir, name));
        f.keep(join(f.versionDir, entry === "app" ? "VoiceBar.zip" : "VoiceBar.app/marker"));
      }
      const result = f.run();
      expect(result.operations).toBe("");
      expect(result.exitCode).toBe(1);
      expect(result.stderr.toString()).toContain("ERROR:");
    }));
  }
}

for (const entry of ["app", "zip"] as const) {
  test(`release rejects ${entry} symlink to a noindex sibling outside the version directory`, () => withReleaseFixture(f => {
    mkdirSync(f.versionDir);
    // Shares the version path prefix, but is not contained in that directory.
    const targetDir = `${f.versionDir}-sibling`;
    const name = entry === "app" ? "VoiceBar.app" : "VoiceBar.zip";
    const target = join(targetDir, name);
    f.keep(entry === "app" ? join(target, "marker") : target);
    f.keep(join(f.versionDir, entry === "app" ? "VoiceBar.zip" : "VoiceBar.app/marker"));
    symlinkSync(target, join(f.versionDir, name));
    const result = f.run();
    expect(result.operations).toBe("");
    expect(result.exitCode).toBe(1);
    expect(result.stderr.toString()).toContain("ERROR:");
  }));
}

for (const mode of ["ordinary", "version-symlink", "contained-child-symlinks"] as const) {
  test(`release accepts valid scratch destinations: ${mode}`, () => withReleaseFixture(f => {
    const selectedDir = mode === "version-symlink" ? join(f.safe, "selected-version") : f.versionDir;
    mkdirSync(selectedDir);
    if (mode === "version-symlink") symlinkSync(selectedDir, f.versionDir);
    const childDir = mode === "contained-child-symlinks" ? join(selectedDir, "nested") : selectedDir;
    const app = join(childDir, "VoiceBar.app");
    const zip = join(childDir, "VoiceBar.zip");
    f.keep(join(app, "marker"));
    f.keep(zip);
    if (mode === "contained-child-symlinks") {
      symlinkSync(app, join(selectedDir, "VoiceBar.app"));
      symlinkSync(zip, join(selectedDir, "VoiceBar.zip"));
    }
    const result = f.run();
    expect(result.exitCode).toBe(73); // Only the intercepted build stops a valid release.
    expect(result.stderr.toString()).toBe("");
    expect(result.operations.split("\n").slice(0, 2)).toEqual([
      `mkdir\t-p\t${selectedDir}`, `cleanup\t${selectedDir}\t${app}\t${zip}`,
    ]);
    expect(result.operations).toContain(`build\tflow-bar/build-app.sh\t--install-path\t${app}\t--no-stop\t--no-relaunch\n`);
  }));
}

for (const mode of ["relative", "symlink-parent", "direct-noindex"]) {
  test(`direct build publishes resolved scratch destinations: ${mode}`, () => withReleaseFixture(f => {
    const destination = mode === "direct-noindex" ? f.safe : join(f.safe, "version");
    mkdirSync(destination, { recursive: true });
    let input = destination;
    if (mode === "relative") input = relative(root, destination);
    if (mode === "symlink-parent") {
      input = join(f.base, "alias");
      symlinkSync(destination, input);
    }
    const hook = join(f.base, "staged-build.sh");
    // Exercise the actual entrypoint and supervisor; replace only compilation.
    writeFileSync(hook, `
if [[ "\${VOICEBAR_RELEASE_STAGED:-0}" == 1 ]]; then
  source "${root}/scripts/lib/noindex-path.sh"
  fixture_stage="$(pwd -P)"
  require_noindex_path "$fixture_stage" || exit 1
  mkdir "$fixture_stage/VoiceBar.app"
  printf built > "$fixture_stage/VoiceBar.app/marker"
  printf zip > "$fixture_stage/VoiceBar.zip"
  exit 0
fi
`);
    const result = Bun.spawnSync(["/bin/bash", "flow-bar/build-app.sh",
      "--install-path", join(input, "VoiceBar.app"), "--zip-path", join(input, "VoiceBar.zip"),
      "--no-stop", "--no-relaunch"], {
      cwd: root, env: { ...process.env, BASH_ENV: hook }, stdout: "pipe", stderr: "pipe",
    });
    expect(result.stderr.toString()).toBe("");
    expect(result.exitCode).toBe(0);
    expect(readFileSync(join(destination, "VoiceBar.app/marker"), "utf8")).toBe("built");
    expect(readFileSync(join(destination, "VoiceBar.zip"), "utf8")).toBe("zip");
  }));
}
