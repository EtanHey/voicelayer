import { expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { withChildFixtureEnv } from "./setup/child-env";

const repo = resolve(import.meta.dir, "../..");
const paths = join(repo, "src/paths.ts");

test("plain production-like children may inherit NODE_ENV=test without becoming test runners", () => {
  const root = mkdtempSync(join(process.env.VOICELAYER_TEST_RUN_ROOT!, "process-"));
  const env = { ...process.env, NODE_ENV: "test", HOME: join(root, "home"),
    VOICELAYER_TMP_ROOT: join(root, "tmp"), VOICELAYER_STATE_DIR: join(root, "state"),
    QA_VOICE_RECORDINGS_DIR: join(root, "archive") };
  try {
    const code = `delete process.env.VOICELAYER_TEST_ISOLATED;
      const p = await import(${JSON.stringify(paths)});
      console.log(JSON.stringify([p.getTmpRoot(), p.getStateDir(), p.getRecordingsArchiveRoot()]));`;
    const child = withChildFixtureEnv(env, () => spawnSync(process.execPath, ["-e", code], {
      env, encoding: "utf8", timeout: 15_000,
    }));
    expect(child.stderr).toBe("");
    expect(child.status).toBe(0);
    expect(JSON.parse(child.stdout)).toEqual([env.VOICELAYER_TMP_ROOT, env.VOICELAYER_STATE_DIR, env.QA_VOICE_RECORDINGS_DIR]);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test("plain children retaining the preload environment keep its isolated roots", () => {
  const child = spawnSync(process.execPath, ["-e", `
    const p = await import(${JSON.stringify(paths)});
    console.log(JSON.stringify([p.getTmpRoot(), p.getStateDir(), p.getRecordingsArchiveRoot()]));
  `], { env: process.env, encoding: "utf8", timeout: 15_000 });
  expect(child.stderr).toBe("");
  expect(child.status).toBe(0);
  expect(JSON.parse(child.stdout)).toEqual([
    process.env.VOICELAYER_TMP_ROOT, process.env.VOICELAYER_STATE_DIR, process.env.QA_VOICE_RECORDINGS_DIR,
  ]);
});

test("actual Bun runners refuse arbitrary fixture names even with NODE_ENV=production", () => {
  const root = mkdtempSync(join(process.env.VOICELAYER_TEST_RUN_ROOT!, "runner-"));
  const env = { ...process.env, NODE_ENV: "production", HOME: join(root, "home"),
    VOICELAYER_TMP_ROOT: join(root, "tmp"), VOICELAYER_STATE_DIR: join(root, "state"),
    QA_VOICE_RECORDINGS_DIR: join(root, "archive") };
  const fixture = join(root, "arbitrary.ts"), config = join(root, "empty.toml");
  mkdirSync(env.VOICELAYER_TMP_ROOT);
  writeFileSync(config, "[test]\n");
  writeFileSync(fixture, `import {test} from 'bun:test';
    delete process.env.VOICELAYER_TEST_ISOLATED;
    test('unisolated runner', async () => { await import(${JSON.stringify(paths)}); });`);
  try {
    const child = withChildFixtureEnv(env, () => spawnSync(process.execPath, ["test", `--config=${config}`, fixture], {
      cwd: join(repo, "src/__tests__"), env, encoding: "utf8", timeout: 15_000,
    }));
    expect(child.status).not.toBe(0);
    expect(child.stderr).toContain("test requires the isolation preload");
  } finally { rmSync(root, { recursive: true, force: true }); }
});
