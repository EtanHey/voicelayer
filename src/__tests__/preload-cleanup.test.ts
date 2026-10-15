import { afterEach, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "fs";
import { join, resolve } from "path";

const preload = resolve("src/__tests__/setup/preload.ts");
const fixtures: string[] = [];
function sandbox() {
  const dir = mkdtempSync(join(process.env.VOICELAYER_TEST_RUN_ROOT!, "hyg3-"));
  fixtures.push(dir);
  return dir;
}
function child(cwd: string, source = "", extra: Record<string, string> = {}) {
  writeFileSync(join(cwd, "fixture.test.ts"), `import { test, expect } from "bun:test";\n${source}\n`);
  const env = { ...process.env, ...extra };
  for (const key of ["VOICELAYER_TEST_KEEP_TMP", "VOICELAYER_KEEP_TEST_TMP"]) {
    if (!(key in extra)) delete env[key];
  }
  return Bun.spawn([process.execPath, "test", "--preload", preload, "./fixture.test.ts"], {
    cwd, env, stdout: "pipe", stderr: "pipe",
  });
}
async function finish(proc: ReturnType<typeof child>) {
  const [code, stdout, stderr] = await Promise.all([
    proc.exited, new Response(proc.stdout).text(), new Response(proc.stderr).text(),
  ]);
  return { code, stdout, stderr };
}
afterEach(() => { for (const dir of fixtures.splice(0)) rmSync(dir, { recursive: true, force: true }); });

test("clean child removes its run directory", async () => {
  const dir = sandbox();
  const proc = child(dir, 'test("pass", () => expect(true).toBe(true));');
  expect((await finish(proc)).code).toBe(0);
  expect(existsSync(join(dir, ".test-tmp", String(proc.pid)))).toBe(false);
});

test("failed child keeps evidence across the next startup sweep", async () => {
  const dir = sandbox();
  const proc = child(dir, 'test("fail", () => expect(true).toBe(false));');
  expect((await finish(proc)).code).toBe(1);
  const root = join(dir, ".test-tmp", String(proc.pid));
  expect(existsSync(root)).toBe(true);
  expect((await finish(child(dir))).code).toBe(0);
  expect(existsSync(root)).toBe(true);
});

for (const flag of ["VOICELAYER_KEEP_TEST_TMP", "VOICELAYER_TEST_KEEP_TMP"]) {
  test(`${flag} preserves successful evidence across sweeps`, async () => {
    const dir = sandbox();
    const proc = child(dir, "", { [flag]: "1" });
    expect((await finish(proc)).code).toBe(0);
    const root = join(dir, ".test-tmp", String(proc.pid));
    expect(existsSync(root)).toBe(true);
    expect((await finish(child(dir))).code).toBe(0);
    expect(existsSync(root)).toBe(true);
  });
}

test("startup sweeps dead PID directories and leaves live and unrelated entries", async () => {
  const dir = sandbox();
  const dead = child(dir, "", { VOICELAYER_KEEP_TEST_TMP: "1" });
  await finish(dead);
  const deadRoot = join(dir, ".test-tmp", String(dead.pid));
  // Simulate an unmarked directory abandoned by an older run or SIGKILL.
  rmSync(deadRoot, { recursive: true, force: true });
  mkdirSync(deadRoot);
  const liveRoot = join(dir, ".test-tmp", String(process.pid));
  const unrelated = join(dir, ".test-tmp", "not-a-pid");
  mkdirSync(liveRoot); mkdirSync(unrelated);
  expect((await finish(child(dir))).code).toBe(0);
  expect(existsSync(deadRoot)).toBe(false);
  expect(existsSync(liveRoot)).toBe(true);
  expect(existsSync(unrelated)).toBe(true);
});

for (const signal of ["SIGINT", "SIGTERM"] as const) {
  test(`${signal} keeps interrupted evidence and exits with signal status`, async () => {
    const dir = sandbox();
    const proc = child(dir, 'console.log("READY"); await new Promise(() => setInterval(() => {}, 1000));');
    const reader = proc.stdout.getReader();
    await reader.read();
    reader.releaseLock();
    proc.kill(signal);
    const [code] = await Promise.all([proc.exited, new Response(proc.stderr).text()]);
    expect(code).toBe(signal === "SIGINT" ? 130 : 143);
    expect(existsSync(join(dir, ".test-tmp", String(proc.pid)))).toBe(true);
  });
}

test("a symlinked temp root never writes or sweeps outside the worktree", async () => {
  const dir = sandbox();
  const outside = sandbox();
  const sentinel = join(outside, "2147483647");
  mkdirSync(sentinel);
  symlinkSync(outside, join(dir, ".test-tmp"));
  expect((await finish(child(dir))).code).not.toBe(0);
  expect(existsSync(sentinel)).toBe(true);
});

test("explicit nonzero process exit keeps failure evidence", async () => {
  const dir = sandbox();
  const env = { ...process.env };
  delete env.VOICELAYER_KEEP_TEST_TMP;
  delete env.VOICELAYER_TEST_KEEP_TMP;
  const proc = Bun.spawn([process.execPath, "--preload", preload, "-e", "process.exit(1)"], {
    cwd: dir, env, stdout: "pipe", stderr: "pipe",
  });
  expect((await finish(proc)).code).toBe(1);
  expect(existsSync(join(dir, ".test-tmp", String(proc.pid)))).toBe(true);
});
