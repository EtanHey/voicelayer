import { expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { isAbsolute, join, relative, resolve, sep } from "node:path";
import { requireIsolatedOverride } from "../test-isolation";
import { withChildFixtureEnv } from "./setup/child-env";

const repo = resolve(import.meta.dir, "../..");
const testRoot = join(repo, ".test-tmp");
const pathsModule = join(repo, "src/paths.ts");

test("test resolvers refuse a missing preload even with explicit path overrides", () => {
  for (const isolated of [undefined, "", "0"]) {
    withChildFixtureEnv({ VOICELAYER_TEST_ISOLATED: isolated }, () => {
      expect(() => requireIsolatedOverride({ VOICELAYER_TMP_ROOT: "/synthetic-only" },
        "VOICELAYER_TMP_ROOT")).toThrow("test requires the isolation preload");
    });
  }
  expect(() => requireIsolatedOverride({
    NODE_ENV: "test", VOICELAYER_TEST_ISOLATED: "1",
  }, "VOICELAYER_TMP_ROOT")).toThrow("isolated test requires VOICELAYER_TMP_ROOT");
  expect(() => requireIsolatedOverride({}, "VOICELAYER_TMP_ROOT")).not.toThrow();
});

function within(root: string, path: string): boolean {
  const tail = relative(root, path);
  return !isAbsolute(tail) && tail !== ".." && !tail.startsWith(`..${sep}`);
}

for (const cwd of ["src/__tests__", "tests", "src/__tests__/setup"]) {
  test(`bun test from ${cwd} isolates history/archive or refuses before access`, () => {
    const sandbox = mkdtempSync(join(process.env.VOICELAYER_TEST_RUN_ROOT!, "cwd-"));
    const home = join(sandbox, "home");
    // Preload artifacts also belong within this fake TMPDIR, never system /tmp.
    const tmp = testRoot;
    mkdirSync(home);
    const fixture = join(sandbox, "paths.test.ts");
    const report = join(home, "paths.json");
    const config = join(sandbox, "empty.toml");
    writeFileSync(config, "[test]\n");
    writeFileSync(fixture, `
      import { expect, test } from "bun:test";
      import { existsSync, mkdirSync, writeFileSync } from "node:fs";
      import { isAbsolute, join, relative, sep } from "node:path";
      test("history/archive access stays inside fake HOME or TMPDIR", async () => {
        const inside = (root, path) => {
          const tail = relative(root, path);
          return !isAbsolute(tail) && tail !== ".." && !tail.startsWith(".." + sep);
        };
        const p = await import(${JSON.stringify(pathsModule)});
        // RED stops here before any resolver output is read or written.
        expect(process.env.VOICELAYER_TEST_ISOLATED).toBe("1");
        const paths = [p.TTS_HISTORY_FILE, p.ttsHistoryFilePath(0),
          p.getRecordingsArchiveRoot(), p.getTmpRoot(), p.getStateDir(),
          p.SOCKET_PATH, p.MCP_SOCKET_PATH, p.STOP_FILE, p.CANCEL_FILE, p.LOCK_FILE];
        for (const path of paths) {
          expect(inside(process.env.HOME, path) || inside(process.env.TMPDIR, path)).toBe(true);
        }
        expect(existsSync(process.env.VOICELAYER_TEST_FAKE_REC_BIN)).toBe(true);
        writeFileSync(p.TTS_HISTORY_FILE, "sandbox history");
        mkdirSync(p.getRecordingsArchiveRoot(), { recursive: true });
        writeFileSync(join(p.getRecordingsArchiveRoot(), "sandbox-entry"), "sandbox archive");
        writeFileSync(${JSON.stringify(report)}, JSON.stringify(paths));
      });
    `);
    const env = { ...process.env };
    for (const key of Object.keys(env)) {
      if (/^(VOICELAYER_|QA_VOICE_|XDG_)/.test(key)) env[key] = undefined;
    }
    Object.assign(env, {
      HOME: home, TMPDIR: tmp, NODE_ENV: "test",
      // Safe even on the old code, whose /tmp fallback ignores TMPDIR.
      VOICELAYER_TMP_ROOT: join(home, "tmp"),
      VOICELAYER_STATE_DIR: join(home, "state"),
      QA_VOICE_RECORDINGS_DIR: join(home, "archive"),
    });
    mkdirSync(env.VOICELAYER_TMP_ROOT!, { recursive: true });
    const run = (args: string[]) => withChildFixtureEnv(env, () => spawnSync(process.execPath, args, {
      cwd: join(repo, cwd), env, encoding: "utf8", timeout: 15_000,
    }));
    try {
      const result = run(["test", fixture]);
      expect(result.error).toBeUndefined();
      // A directory without a bunfig must fail closed; configured dirs must load it.
      if (cwd.endsWith("/setup")) {
        expect(result.status).not.toBe(0);
        expect(result.stderr).toContain("test requires the isolation preload");
        expect(existsSync(report)).toBe(false);
      } else {
        expect(result.stderr).not.toContain("Cannot find preload");
        expect(result.status).toBe(0);
        const paths: string[] = JSON.parse(readFileSync(report, "utf8"));
        expect(paths.every(path => within(home, path) || within(tmp, path))).toBe(true);
        expect(readFileSync(paths[0]!, "utf8")).toBe("sandbox history");
        expect(readFileSync(join(paths[2]!, "sandbox-entry"), "utf8")).toBe("sandbox archive");
        rmSync(report);
      }
      // Explicitly bypass local configs: refuse on import, before even mkdirSync.
      rmSync(join(home, "state"), { recursive: true, force: true });
      const refused = run(["test", `--config=${config}`, fixture]);
      expect(refused.status).not.toBe(0);
      expect(refused.stderr).toContain("test requires the isolation preload");
      expect(existsSync(join(home, "state"))).toBe(false);
      expect(existsSync(report)).toBe(false);
      // Everything this child could resolve for I/O was checked before access.
      expect(readdirSync(sandbox).sort()).toEqual(["empty.toml", "home", "paths.test.ts"]);
    } finally {
      rmSync(sandbox, { recursive: true, force: true });
    }
  }, 30_000);
}
