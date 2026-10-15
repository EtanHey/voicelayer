import { afterEach, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, rmSync, symlinkSync, utimesSync, writeFileSync } from "fs";
import { join, resolve } from "path";

const preload = resolve("src/__tests__/setup/preload.ts");
const fixtures: string[] = [];
function sandbox() {
  const dir = mkdtempSync(join(process.env.VOICELAYER_TEST_RUN_ROOT!, "hyg3-"));
  fixtures.push(dir);
  return dir;
}
function run(cwd: string, testRunner = false) {
  const env = { ...process.env };
  for (const key of [
    "VOICELAYER_TMP_ROOT", "VOICELAYER_STATE_DIR", "QA_VOICE_RECORDINGS_DIR",
    "VOICELAYER_CONTROL_LAYER_BASE", "VOICELAYER_SOCKET_PATH", "VOICELAYER_MCP_SOCKET_PATH",
  ]) delete env[key];
  const args = testRunner
    ? ["test", "--preload", preload, "./pass.test.ts"]
    : ["--preload", preload, "-e", "void 0;"];
  if (testRunner) writeFileSync(join(cwd, "pass.test.ts"), 'import { test } from "bun:test"; test("pass", () => {});');
  return Bun.spawnSync([process.execPath, ...args], {
    cwd, env, stdout: "pipe", stderr: "pipe",
  });
}
function deadPids(count: number): number[] {
  const pids: number[] = [];
  // Real reaped children provide known-dead PIDs without assuming the OS PID limit.
  for (let i = 0; i < count; i++) {
    const proc = Bun.spawnSync([process.execPath, "-e", "void 0;"], { stdout: "ignore", stderr: "ignore" });
    expect(proc.exitCode).toBe(0);
    expect(() => process.kill(proc.pid, 0)).toThrow();
    pids.push(proc.pid);
  }
  return pids;
}
function fixture(cwd: string, pid: number | string, age: number) {
  const dir = join(cwd, ".test-tmp", String(pid));
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "evidence"), "keep me");
  const date = new Date(Date.now() - age * 1000);
  utimesSync(dir, date, date);
  return dir;
}
afterEach(() => { for (const dir of fixtures.splice(0)) rmSync(dir, { recursive: true, force: true }); });

test("startup removes older dead PID directories and keeps the newest two", () => {
  const dir = sandbox();
  const roots = deadPids(5).map((pid, i) => fixture(dir, pid, 100 - i * 10));
  expect(run(dir, true).exitCode).toBe(0);
  expect(roots.map(root => existsSync(root))).toEqual([false, false, false, true, true]);
});

test("live PID directories are never swept or counted toward the two dead survivors", () => {
  const dir = sandbox();
  const live = fixture(dir, process.pid, 1000);
  const dead = deadPids(3).map((pid, i) => fixture(dir, pid, 100 - i * 10));
  expect(run(dir).exitCode).toBe(0);
  expect(existsSync(join(live, "evidence"))).toBe(true);
  expect(dead.map(root => existsSync(root))).toEqual([false, true, true]);
});

test("zero, one and two dead siblings retain all evidence", () => {
  for (const count of [0, 1, 2]) {
    const dir = sandbox();
    const roots = deadPids(count).map(pid => fixture(dir, pid, 100));
    expect(run(dir).exitCode).toBe(0);
    expect(roots.every(root => existsSync(root))).toBe(true);
  }
});

test("sweep ignores unrelated entries and never follows sibling symlinks", () => {
  const dir = sandbox();
  const outside = sandbox();
  const sentinel = fixture(outside, "outside-evidence", 1000);
  const dead = deadPids(4);
  const unrelated = fixture(dir, "not-a-pid", 1000);
  const zero = fixture(dir, "0", 1000);
  const link = join(dir, ".test-tmp", String(dead[0]));
  symlinkSync(sentinel, link);
  const roots = dead.slice(1).map((pid, i) => fixture(dir, pid, 100 - i * 10));
  expect(run(dir).exitCode).toBe(0);
  expect(existsSync(sentinel)).toBe(true);
  expect(existsSync(join(sentinel, "evidence"))).toBe(true);
  expect(existsSync(link)).toBe(true);
  expect(existsSync(unrelated)).toBe(true);
  expect(existsSync(zero)).toBe(true);
  expect(roots.map(root => existsSync(root))).toEqual([false, true, true]);
});

test("a symlinked .test-tmp root is refused before any outside write or deletion", () => {
  const dir = sandbox();
  const outside = sandbox();
  const roots = deadPids(3).map(pid => fixture(outside, pid, 100));
  // Numeric siblings in the redirected outside root must survive.
  symlinkSync(join(outside, ".test-tmp"), join(dir, ".test-tmp"));
  const proc = run(dir);
  expect(proc.exitCode).not.toBe(0);
  expect(roots.every(root => existsSync(root))).toBe(true);
  expect(existsSync(join(outside, ".test-tmp", String(proc.pid)))).toBe(false);
});
