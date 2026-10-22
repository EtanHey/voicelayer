import { expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, writeFileSync, rmSync, symlinkSync } from "node:fs";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";
import { bundleFixtureRoot } from "./setup/bundle-fixtures";

const root = resolve(import.meta.dir, "../..");
const buildRoot = join(root, ".build.noindex");
mkdirSync(buildRoot, { recursive: true });

// Scan all shell/Python helpers, including new files. An app destination must
// have a literal safe ancestor or a checked variable in its assignment chain.
function violations(source: string): string[] {
  const checked = new Set<string>();
  for (const match of source.matchAll(/require_noindex_path\s+"\$\{?(\w+)\}?"/g)) checked.add(match[1]!);
  const safe = new Set(checked);
  // Persistent rollback ZIPs are allowed outside Spotlight build roots.
  if (source.includes('require_non_docslocal_path "$VOICEBAR_BACKUP_DIR"')) safe.add("VOICEBAR_BACKUP_DIR");
  const assignments = [...source.matchAll(/^\s*(?:local )?(\w+)=["']?([^\n]+)/gm)];
  const valueSafe = (value: string) => !/(?:^|\/)docs\.local\//i.test(value) && (/\/Applications\//.test(value) || /\.noindex(?:[\/"']|$)/.test(value)
    || [...safe].some(name => value === `$${name}` || value === `\${${name}}` || value.includes(`$${name}/`) || value.includes(`\${${name}}/`)));
  for (let pass = 0; pass < assignments.length; pass++) {
    for (const match of assignments) if (valueSafe(match[2]!)) safe.add(match[1]!);
  }
  const errors: string[] = [];
  for (const line of source.split("\n")) {
    if (/^\s*#/.test(line)) continue;
    const assignment = line.match(/^\s*(?:local )?(\w+)=["']?(.+\.(?:app|zip|dmg|tgz)["']?)$/);
    if (assignment && !checked.has(assignment[1]!) && !valueSafe(assignment[2]!)) errors.push(line.trim());
    for (const match of line.matchAll(/--install-path\s+["']?((?:\/|\$)[^\s"'`]+\.app)/g)) {
      if (!valueSafe(match[1]!)) errors.push(line.trim());
    }
    // Catch direct literal destinations as well as named app variables.
    if (/^\s*(?:mkdir|cp|mv|ditto)\s/.test(line)) {
      for (const match of line.matchAll(/["']?([^\s"']+\.app)(?:[\/"'\s]|$)/g)) {
        if (!valueSafe(match[1]!)) errors.push(line.trim());
      }
    }
    for (const match of line.matchAll(/(?:-derivedDataPath|--scratch-path|--basetemp(?:=|\s+))\s*["']?([^\s"']+)/g)) {
      if (!valueSafe(match[1]!)) errors.push(line.trim());
    }
  }
  // App-shaped TypeScript fixtures must use the isolated noindex bundle root.
  if (/join\([^\n]*['"][^'"\n]*\.app['"]/.test(source) && /mkdirSync|writeFileSync/.test(source)) {
    for (const line of source.split("\n")) {
      if (/mkdtempSync\(join\((?:tmpdir\(\)|process\.env\.TMPDIR)/.test(line)) errors.push(line.trim());
    }
  }
  // Python fixture roots can create bundle directories indirectly through pathlib.
  if (/[\w-]+\.app['"]/.test(source) && source.includes("TemporaryDirectory(")) {
    for (const line of source.split("\n")) {
      if (line.includes("tempfile.TemporaryDirectory(") && !line.includes("suffix='.noindex'")) errors.push(line.trim());
    }
  }
  return errors;
}

test("bundle writers and DerivedData stay outside Spotlight", async () => {
  const failures: string[] = [];
  const glob = new Bun.Glob("**/*");
  let scanned = 0;
  for await (const path of glob.scan({ cwd: root })) {
    if (!/^(scripts\/.*\.(sh|py|ts)|flow-bar\/[^/]+\.sh|(?:AGENTS|CLAUDE.details)\.md|docs\/.*\.md|flow-bar\/UIE2E\/README\.md|(?:src\/__tests__|tests)\/.*\.test\.ts)$/.test(path)) continue;
    if (path.endsWith("noindex-artifacts.test.ts")) continue;
    scanned++;
    const ref = process.env.NOINDEX_LINT_REF;
    const content = ref ? Bun.spawnSync(["git", "show", `${ref}:${path}`], { cwd: root, env: process.env, stdout: "pipe", stderr: "pipe" }).stdout.toString() : readFileSync(resolve(root, path), "utf8");
    for (const line of violations(content)) failures.push(`${path}: ${line}`);
  }
  expect(scanned).toBeGreaterThan(20);
  expect(failures).toEqual([]);
});

test("lint rejects new unsafe writers and accepts checked paths", () => {
  expect(violations('app="$output/QA.app"\nxcodebuild -derivedDataPath "$output/DerivedData"')).toHaveLength(2);
  expect(violations('app="/Applications/QA.app"\napp="$output.noindex/QA.app"')).toEqual([]);
  expect(violations('require_noindex_path "$output"\napp="$output/QA.app"')).toEqual([]);
  expect(violations('mkdir -p /tmp/QA.app/Contents')).toHaveLength(1);
  expect(violations('bash flow-bar/build-app.sh --install-path /tmp/QA.app')).toHaveLength(1);
  expect(violations('app="docs.local/qa.noindex/QA.app"')).toHaveLength(1);
  expect(violations('pytest --basetemp /tmp/test-apps')).toHaveLength(1);
  expect(violations('archive="/tmp/VoiceBar.zip"')).toHaveLength(1);
  expect(violations('app="/Applications/QA.app"\napp="/tmp/QA.app"')).toHaveLength(1);
});


test("output guard rejects unsafe overrides and symlink escapes before writing", () => {
  const temp = mkdtempSync(join(tmpdir(), "noindex-policy-"));
  const safe = join(temp, "artifacts.noindex");
  const outside = join(temp, "indexed");
  mkdirSync(safe);
  mkdirSync(outside);
  symlinkSync(outside, join(safe, "escape"));
  const guard = join(root, "scripts/lib/noindex-path.sh");
  const check = (path: string) => Bun.spawnSync(["bash", "-c",
    'source "$1"; require_noindex_path "$2"', "test", guard, path],
    { env: process.env, stdout: "pipe", stderr: "pipe" });
  try {
    for (const path of ["/Applications/VoiceBar.app", join(safe, "QA.app")]) expect(check(path).exitCode).toBe(0);
    for (const path of [join(outside, "QA.app"), join(safe, "../QA.app"), join(safe, "escape/QA.app"), join(safe, "docs.local/QA.app"), join(safe, "docs.LOCAL/QA.app")]) {
      expect(check(path).exitCode).not.toBe(0);
    }
    const unsafe = join(temp, "not-created");
    for (const args of [
      ["flow-bar/build-app.sh", "--install-path", unsafe + ".app", "--no-stop", "--no-relaunch"],
      ["scripts/release-voicebar.sh", "--output-dir", unsafe, "--skip-tap-check"],
      ["flow-bar/build-app.sh", "--install-path", join(safe, "QA.app"), "--zip-path", unsafe + ".zip", "--no-stop", "--no-relaunch"],
      ["scripts/voicebar-ui-e2e.sh", "--output", unsafe, "--build-only"],
    ]) {
      const result = Bun.spawnSync(["bash", ...args], { cwd: root, env: process.env, stdout: "pipe", stderr: "pipe" });
      expect(result.exitCode).not.toBe(0);
      expect(result.stderr.toString()).toContain("*.noindex");
      expect(existsSync(unsafe)).toBe(false);
      expect(existsSync(unsafe + ".app")).toBe(false);
    }
  } finally { rmSync(temp, { recursive: true, force: true }); }
});



for (const scenario of ["version", "app", "zip", "docs.local", "dot-segments"]) test(`release rejects ${scenario} destination before deleting artifacts`, () => {
  const fixture = mkdtempSync(join(tmpdir(), "release-guard-"));
  const version = JSON.parse(readFileSync(join(root, "package.json"), "utf8")).version;
  try {
    {
      const base = join(fixture, scenario);
      const safe = join(base, "artifacts.noindex");
      const outside = join(base, "indexed");
      const target = scenario === "docs.local" ? join(safe, "docs.local") : outside;
      mkdirSync(target, { recursive: true });
      mkdirSync(safe, { recursive: true });
      const app = join(target, "VoiceBar.app");
      const zip = join(target, "VoiceBar.zip");
      mkdirSync(app);
      writeFileSync(join(app, "marker"), "keep app");
      writeFileSync(zip, "keep zip");
      const versionDir = join(safe, version);
      if (scenario === "version" || scenario === "docs.local") {
        symlinkSync(target, versionDir);
      } else {
        mkdirSync(versionDir);
        if (scenario === "app") symlinkSync(app, join(versionDir, "VoiceBar.app"));
        if (scenario === "zip") symlinkSync(zip, join(versionDir, "VoiceBar.zip"));
        // A safe sibling must also survive when another final destination fails.
        if (scenario === "zip") writeFileSync(join(versionDir, "VoiceBar.app"), "keep sibling");
      }
      const output = scenario === "dot-segments" ? `${safe}/../indexed` : safe;
      const result = Bun.spawnSync(["bash", "scripts/release-voicebar.sh", "--output-dir", output, "--skip-tap-check"],
        { cwd: root, env: process.env, stdout: "pipe", stderr: "pipe" });
      expect(result.exitCode).not.toBe(0);
      expect(result.stderr.toString()).toContain(scenario === "docs.local" ? "docs.local holds only" : "*.noindex");
      expect(result.stdout.toString()).not.toContain("Building notarized");
      expect(readFileSync(join(app, "marker"), "utf8")).toBe("keep app");
      expect(readFileSync(zip, "utf8")).toBe("keep zip");
      if (scenario === "zip") expect(readFileSync(join(versionDir, "VoiceBar.app"), "utf8")).toBe("keep sibling");
    }
  } finally { rmSync(fixture, { recursive: true, force: true }); }
});

test("rollback backups allow persistent storage and reject docs.local", () => {
  const guard = join(root, "scripts/lib/noindex-path.sh");
  const check = (path: string) => Bun.spawnSync(["bash", "-c",
    'source "$1"; require_non_docslocal_path "$2"', "test", guard, path],
    { env: process.env, stdout: "pipe", stderr: "pipe" }).exitCode;
  expect(check(join(buildRoot, "synthetic-home/Library/Application Support/VoiceBar/Backups"))).toBe(0);
  for (const name of ["docs.local", "docs.LOCAL"]) expect(check(join(buildRoot, name, "backups"))).not.toBe(0);
  expect(violations('require_non_docslocal_path "$VOICEBAR_BACKUP_DIR"\nbackup_path="$VOICEBAR_BACKUP_DIR/VoiceBar.app.zip"')).toEqual([]);
  expect(violations('require_non_docslocal_path "$VOICEBAR_BACKUP_DIR"\nbackup_path="docs.LOCAL/VoiceBar.app.zip"')).toHaveLength(1);
});

test("bundle fixtures stay in the swept per-run noindex root", () => {
  expect(bundleFixtureRoot()).toBe(join(process.env.VOICELAYER_TEST_RUN_ROOT!, "fixtures.noindex"));
  expect(violations('app="$run/fixtures.noindex/QA.app"')).toEqual([]);
});

test("docs.local hygiene and archive filter use synthetic fixtures", () => {
  const fixture = mkdtempSync(join(buildRoot, "receipt-fixture-"));
  const source = join(fixture, "docs.local");
  mkdirSync(source);
  const run = (script: string, ...args: string[]) => Bun.spawnSync(["python3", join(root, "scripts", script), ...args], { env: process.env, stdout: "pipe", stderr: "pipe" });
  try {
    writeFileSync(join(source, "receipt.log"), "small receipt");
    expect(run("check-docslocal-hygiene.py", source).exitCode).toBe(0);
    for (const name of ["QA.app", "derivedData", ".build.noindex", "Mixed.APP", ".BUILD-cache"]) {
      mkdirSync(join(source, name));
      expect(run("check-docslocal-hygiene.py", source).exitCode).not.toBe(0);
      rmSync(join(source, name), { recursive: true });
    }
    for (const name of ["QA.app", "derivedData", ".build.noindex", "Mixed.APP", ".BUILD-cache"]) mkdirSync(join(source, name));
    for (const name of ["app.zip", "app.dmg", "app.tgz", "mixed.Zip", "mixed.DMG", "mixed.TgZ"]) writeFileSync(join(source, name), "binary");
    writeFileSync(join(source, "large.log"), Buffer.alloc(5 * 1024 * 1024 + 1));
    writeFileSync(join(source, "executable"), Buffer.from("cffaedfe00000000", "hex"));
    symlinkSync(source, join(source, "cycle"));
    expect(run("check-docslocal-hygiene.py", source).exitCode).not.toBe(0);
    const dest = join(fixture, "archive");
    expect(run("archive-worktree-docs.py", source, dest).exitCode).toBe(0);
    expect(run("check-docslocal-hygiene.py", dest).exitCode).toBe(0);
    expect(readFileSync(join(dest, "receipt.log"), "utf8")).toBe("small receipt");
    expect(readdirSync(dest)).toEqual(["receipt.log"]);
    expect(run("archive-worktree-docs.py", source, dest).exitCode).not.toBe(0);
  } finally { rmSync(fixture, { recursive: true, force: true }); }
});
