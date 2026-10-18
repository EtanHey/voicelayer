import { afterEach, expect, test } from "bun:test";
import { existsSync, readFileSync, readdirSync, mkdirSync, mkdtempSync, rmSync, symlinkSync, utimesSync, writeFileSync } from "fs";
import { basename, join, resolve } from "path";

// Real subprocesses: standalone p95 <= 56 ms; 4x rounded up, with a 5 s scheduling floor.
const SUBPROCESS_TEST_TIMEOUT_MS = 5_000;

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
    const proc = Bun.spawnSync([process.execPath, "-e", "void 0;"], { env: process.env, stdout: "ignore", stderr: "ignore" });
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
  const roots = deadPids(5).map((pid, i) => fixture(dir, i % 2 ? `${pid}-cafe` : pid, 100 - i * 10));
  expect(run(dir, true).exitCode).toBe(0);
  expect(roots.map(root => existsSync(root))).toEqual([false, false, false, true, true]);
}, SUBPROCESS_TEST_TIMEOUT_MS);

test("live PID directories are never swept or counted toward the two dead survivors", () => {
  const dir = sandbox();
  const live = fixture(dir, process.pid, 1000);
  const generation = fixture(dir, `${process.pid}-cafe`, 1000);
  const dead = deadPids(3).map((pid, i) => fixture(dir, pid, 100 - i * 10));
  expect(run(dir).exitCode).toBe(0);
  expect(existsSync(join(live, "evidence"))).toBe(true);
  expect(existsSync(join(generation, "evidence"))).toBe(true);
  expect(dead.map(root => existsSync(root))).toEqual([false, true, true]);
}, SUBPROCESS_TEST_TIMEOUT_MS);

test("zero, one and two dead siblings retain all evidence", () => {
  for (const count of [0, 1, 2]) {
    const dir = sandbox();
    const roots = deadPids(count).map(pid => fixture(dir, pid, 100));
    expect(run(dir).exitCode).toBe(0);
    expect(roots.every(root => existsSync(root))).toBe(true);
  }
}, SUBPROCESS_TEST_TIMEOUT_MS);

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
}, SUBPROCESS_TEST_TIMEOUT_MS);

test("a symlinked .test-tmp root is refused before any outside write or deletion", () => {
  const dir = sandbox();
  const outside = sandbox();
  const roots = deadPids(3).map(pid => fixture(outside, pid, 100));
  // Numeric siblings in the redirected outside root must survive.
  symlinkSync(join(outside, ".test-tmp"), join(dir, ".test-tmp"));
  const proc = run(dir);
  expect(proc.exitCode).not.toBe(0);
  expect(roots.every(root => existsSync(root))).toBe(true);
  expect(readdirSync(join(outside, ".test-tmp")).sort()).toEqual(roots.map(root => basename(root)).sort());
}, SUBPROCESS_TEST_TIMEOUT_MS);

test("PID reuse between the final liveness check and deletion cannot erase the new run", () => {
  const dir = sandbox();
  const [reused, newer1, newer2] = deadPids(3);
  const old = fixture(dir, reused, 1000);
  fixture(dir, newer1, 20);
  fixture(dir, newer2, 10);
  const replacement = `
    import * as fs from "fs";
    Object.defineProperty(process, "pid", { value: ${reused} });
    const kill = process.kill.bind(process);
    process.kill = (pid, signal) => pid === ${reused} ? true : kill(pid, signal);
    await import(${JSON.stringify(preload)});
    const root = process.env.VOICELAYER_TEST_RUN_ROOT;
    fs.writeFileSync(root + "/active-evidence", "active run");
    fs.writeFileSync(process.cwd() + "/replacement.json", JSON.stringify(root));
    setInterval(() => {}, 1000);
  `;
  const sweeper = `
    import * as fs from "fs";
    import { mock } from "bun:test";
    let adopted, replacementProcess;
    const remove = fs.rmSync;
    mock.module("fs", () => ({ ...fs, rmSync(path, options) {
      if (path === ${JSON.stringify(old)}) {
        // Pause A after its final liveness check. B starts with the recycled
        // PID and writes evidence before A resumes the pending deletion.
        replacementProcess = Bun.spawn([process.execPath, "-e", ${JSON.stringify(replacement)}], {
        env: process.env,
          cwd: process.cwd(), env: process.env, stdout: "ignore", stderr: "ignore",
        });
        const marker = process.cwd() + "/replacement.json";
        const deadline = Date.now() + 2000;
        while (!fs.existsSync(marker) && Date.now() < deadline) Bun.sleepSync(5);
        adopted = JSON.parse(fs.readFileSync(marker, "utf8"));
        // Verify B is still running when A resumes deletion.
        process.kill(replacementProcess.pid, 0);
      }
      return remove(path, options);
    }}));
    try {
      await import(${JSON.stringify(preload)});
      console.log(JSON.stringify({ adopted }));
    } finally {
      if (replacementProcess) {
        replacementProcess.kill("SIGTERM");
        await replacementProcess.exited;
      }
    }
  `;
  const result = Bun.spawnSync([process.execPath, "-e", sweeper], {
    cwd: dir, env: process.env, stdout: "pipe", stderr: "pipe",
  });
  expect(result.exitCode).toBe(0);
  const { adopted } = JSON.parse(result.stdout.toString().trim());
  expect(typeof adopted).toBe("string");
  expect(existsSync(join(adopted, "active-evidence"))).toBe(true);
  expect(adopted).not.toBe(old);
  expect(existsSync(old)).toBe(false);
}, SUBPROCESS_TEST_TIMEOUT_MS);

test("a nonce collision fails without adopting the existing directory", () => {
  const dir = sandbox();
  const script = `
    import * as fs from "fs";
    import { mock } from "bun:test";
    const mkdir = fs.mkdirSync;
    let collided = false;
    mock.module("fs", () => ({ ...fs, mkdirSync(path, options) {
      if (!collided && String(path).startsWith(process.cwd() + "/.test-tmp/" + process.pid + "-")) {
        collided = true;
        mkdir(path, { recursive: true });
        fs.writeFileSync(path + "/evidence", "original");
        console.log(path);
      }
      return mkdir(path, options);
    }}));
    await import(${JSON.stringify(preload)});
  `;
  const result = Bun.spawnSync([process.execPath, "-e", script], {
    cwd: dir, env: process.env, stdout: "pipe", stderr: "pipe",
  });
  expect(result.exitCode).not.toBe(0);
  expect(result.stderr.toString()).toContain("EEXIST");
  const root = result.stdout.toString().trim();
  expect(readFileSync(join(root, "evidence"), "utf8")).toBe("original");
}, SUBPROCESS_TEST_TIMEOUT_MS);
