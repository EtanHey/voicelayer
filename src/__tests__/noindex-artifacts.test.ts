import { expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync } from "node:fs";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";

const root = resolve(import.meta.dir, "../..");

// Scan all shell/Python helpers, including new files. An app destination must
// have a literal safe ancestor or a checked variable in its assignment chain.
function violations(source: string): string[] {
  const checked = new Set<string>();
  for (const match of source.matchAll(/require_noindex_path\s+"\$\{?(\w+)\}?"/g)) checked.add(match[1]!);
  const safe = new Set(checked);
  const assignments = [...source.matchAll(/^\s*(?:local )?(\w+)=["']?([^\n]+)/gm)];
  const valueSafe = (value: string) => /\/Applications\//.test(value) || /\.noindex(?:[\/"']|$)/.test(value)
    || [...safe].some(name => value.includes(`$${name}/`) || value.includes(`\${${name}}/`));
  for (let pass = 0; pass < assignments.length; pass++) {
    for (const match of assignments) if (valueSafe(match[2]!)) safe.add(match[1]!);
  }
  const errors: string[] = [];
  for (const line of source.split("\n")) {
    if (/^\s*#/.test(line)) continue;
    const assignment = line.match(/^\s*(?:local )?(\w+)=["']?(.+\.app["']?)$/);
    if (assignment && !checked.has(assignment[1]!) && !valueSafe(assignment[2]!)) errors.push(line.trim());
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
    if (!/^(scripts\/.*\.(sh|py)|flow-bar\/[^/]+\.sh)$/.test(path)) continue;
    scanned++;
    for (const line of violations(readFileSync(resolve(root, path), "utf8"))) failures.push(`${path}: ${line}`);
  }
  expect(scanned).toBeGreaterThan(20);
  expect(failures).toEqual([]);
});

test("lint rejects new unsafe writers and accepts checked paths", () => {
  expect(violations('app="$output/QA.app"\nxcodebuild -derivedDataPath "$output/DerivedData"')).toHaveLength(2);
  expect(violations('app="/Applications/QA.app"\napp="$output.noindex/QA.app"')).toEqual([]);
  expect(violations('require_noindex_path "$output"\napp="$output/QA.app"')).toEqual([]);
  expect(violations('mkdir -p /tmp/QA.app/Contents')).toHaveLength(1);
  expect(violations('pytest --basetemp /tmp/test-apps')).toHaveLength(1);
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
    for (const path of [join(outside, "QA.app"), join(safe, "../QA.app"), join(safe, "escape/QA.app")]) {
      expect(check(path).exitCode).not.toBe(0);
    }
    const unsafe = join(temp, "not-created");
    for (const args of [
      ["flow-bar/build-app.sh", "--install-path", unsafe + ".app", "--no-stop", "--no-relaunch"],
      ["scripts/release-voicebar.sh", "--output-dir", unsafe, "--skip-tap-check"],
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
