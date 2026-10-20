import { describe, it, expect, beforeEach, afterEach, spyOn } from "bun:test";
import {
  existsSync,
  mkdirSync,
  writeFileSync,
  unlinkSync,
  readFileSync,
  rmSync,
} from "fs";
import { join } from "path";
import { TEST_TMP } from "./setup/test-tmp";

import {
  acquireProcessLock,
  releaseProcessLock,
  isProcessAlive,
  readProcessStartUs,
} from "../process-lock";

const TEST_PID_FILE = join(
  TEST_TMP,
  `voicelayer-process-lock-test-${process.pid}.pid`,
);

type Fixture = ReturnType<typeof Bun.spawn>;
const fixtureChildren: Fixture[] = [];
const fixtureDirs: string[] = [];
const PROCESS_LOCK_MODULE = join(import.meta.dir, "..", "process-lock.ts");

function cleanPidFile() {
  if (existsSync(TEST_PID_FILE)) {
    try {
      unlinkSync(TEST_PID_FILE);
    } catch {}
  }
}

// Signal only through Bun's own handle, never a stored numeric PID: once a
// fixture has exited, its PID is no longer evidence of that fixture.
async function reapFixtures() {
  while (fixtureChildren.length > 0) {
    const child = fixtureChildren.pop()!;
    if (child.exitCode === null && child.signalCode === null) {
      child.kill("SIGKILL");
    }
    await child.exited;
  }
  while (fixtureDirs.length > 0) {
    rmSync(fixtureDirs.pop()!, { recursive: true, force: true });
  }
}

function fixtureDir(): string {
  const dir = join(TEST_TMP, `lock1-fixture-${process.pid}-${fixtureDirs.length}-${Date.now()}`);
  mkdirSync(dir, { recursive: true });
  fixtureDirs.push(dir);
  return dir;
}

/** An unrelated sleeping process. Returns the wall-clock bracket around spawn. */
function spawnSleeper(argv: string[] = ["/bin/sleep", "3600"]) {
  const beforeMs = Date.now();
  const child = Bun.spawn(argv, { stdout: "ignore", stderr: "ignore", env: process.env });
  const afterMs = Date.now();
  if (!child.pid) throw new Error("fixture failed to start");
  fixtureChildren.push(child);
  return { child, beforeMs, afterMs };
}

/**
 * A genuine owner: a separate process that takes the lock through the
 * production writer, then lingers as an orphan.
 */
async function spawnLockOwner(options: { relative: boolean }) {
  const dir = fixtureDir();
  const entry = "daemon.ts";
  writeFileSync(
    join(dir, entry),
    `import { acquireProcessLock } from ${JSON.stringify(PROCESS_LOCK_MODULE)};\n` +
      `acquireProcessLock(process.argv[2]);\n` +
      `console.log("locked");\n` +
      `await Bun.sleep(3_600_000);\n`,
  );
  const beforeMs = Date.now();
  const child = Bun.spawn(
    ["bun", options.relative ? entry : join(dir, entry), TEST_PID_FILE],
    { cwd: dir, stdout: "pipe", stderr: "ignore", env: process.env },
  );
  fixtureChildren.push(child);
  const reader = (child.stdout as ReadableStream<Uint8Array>).getReader();
  const { value } = await reader.read();
  reader.releaseLock();
  const afterMs = Date.now();
  expect(new TextDecoder().decode(value)).toContain("locked");
  const lock = JSON.parse(readFileSync(TEST_PID_FILE, "utf-8"));
  expect(lock.pid).toBe(child.pid);
  return { child, lock, beforeMs, afterMs };
}

/** The kernel stamps start time at fork, so it lies inside the spawn bracket. */
function expectStartInside(startUs: number, beforeMs: number, afterMs: number) {
  expect(Number.isSafeInteger(startUs)).toBe(true);
  expect(startUs).toBeGreaterThanOrEqual(beforeMs * 1000);
  expect(startUs).toBeLessThan((afterMs + 1) * 1000);
}

/** The kernel start-time reader exists only on Darwin; elsewhere it is absent. */
const nativeStart = process.platform === "darwin";

/** A synthetic generation for decision tests that must not need the native reader. */
const SYNTHETIC_START_US = 1_700_000_000_123_456;

function writeSyntheticLock(pid: number) {
  writeFileSync(
    TEST_PID_FILE,
    JSON.stringify({ pid, startedAt: new Date().toISOString(), processStartUs: SYNTHETIC_START_US }),
  );
}

function sigtermsTo(kill: ReturnType<typeof spyOn>, pid: number): number {
  return kill.mock.calls.filter((call) => call[0] === pid && call[1] === "SIGTERM").length;
}

describe("process lock", () => {
  beforeEach(async () => {
    cleanPidFile();
    await reapFixtures();
  });
  afterEach(async () => {
    await reapFixtures();
    cleanPidFile();
  });

  it("acquires lock when no PID file exists", () => {
    const result = acquireProcessLock(TEST_PID_FILE);
    expect(result.acquired).toBe(true);
    expect(result.killedStale).toBe(false);
    expect(existsSync(TEST_PID_FILE)).toBe(true);

    const content = readFileSync(TEST_PID_FILE, "utf-8");
    const data = JSON.parse(content);
    expect(data.pid).toBe(process.pid);
    expect(typeof data.startedAt).toBe("string");
  });

  it("acquires lock after cleaning stale PID file (dead process)", () => {
    // Write a PID file with a definitely-dead PID
    writeFileSync(
      TEST_PID_FILE,
      JSON.stringify({
        pid: 99999999,
        startedAt: new Date().toISOString(),
      }),
    );

    const result = acquireProcessLock(TEST_PID_FILE);
    expect(result.acquired).toBe(true);
    // killedStale is false — the process was already dead, we didn't kill it
    expect(result.killedStale).toBe(false);
    expect(result.stalePid).toBe(99999999);

    const content = readFileSync(TEST_PID_FILE, "utf-8");
    const data = JSON.parse(content);
    expect(data.pid).toBe(process.pid);
  });

  it("acquires lock when PID file contains corrupt data", () => {
    writeFileSync(TEST_PID_FILE, "not json at all");
    const result = acquireProcessLock(TEST_PID_FILE);
    expect(result.acquired).toBe(true);
  });

  it("acquires lock when PID file is empty", () => {
    writeFileSync(TEST_PID_FILE, "");
    const result = acquireProcessLock(TEST_PID_FILE);
    expect(result.acquired).toBe(true);
  });

  it("releases lock by removing PID file", () => {
    acquireProcessLock(TEST_PID_FILE);
    expect(existsSync(TEST_PID_FILE)).toBe(true);

    releaseProcessLock(TEST_PID_FILE);
    expect(existsSync(TEST_PID_FILE)).toBe(false);
  });

  it("release is idempotent (no error if no file)", () => {
    expect(() => releaseProcessLock(TEST_PID_FILE)).not.toThrow();
  });

  it("detects living process (our own PID)", () => {
    expect(isProcessAlive(process.pid)).toBe(true);
  });

  it("detects dead process (impossible PID)", () => {
    expect(isProcessAlive(99999999)).toBe(false);
  });

  it("handles PID file with valid JSON but missing pid field", () => {
    writeFileSync(TEST_PID_FILE, JSON.stringify({ startedAt: "now" }));
    const result = acquireProcessLock(TEST_PID_FILE);
    expect(result.acquired).toBe(true);
  });

  it("never SIGTERMs a legacy lock without an exact start (e.g. PID 1)", () => {
    writeFileSync(
      TEST_PID_FILE,
      JSON.stringify({
        pid: 1,
        startedAt: new Date().toISOString(),
      }),
    );

    const kill = spyOn(process, "kill").mockImplementation((_pid, signal) => {
      if (signal === 0) return true;
      throw Object.assign(new Error("synthetic EPERM"), { code: "EPERM" });
    });
    let result;
    try {
      result = acquireProcessLock(TEST_PID_FILE);
      expect(kill.mock.calls).toEqual([[1, 0]]);
    } finally {
      kill.mockRestore();
    }
    expect(result.acquired).toBe(true);
    expect(result.killedStale).toBe(false);
    expect(result.stalePid).toBe(1);
  });

  it("can refuse an alive owner without killing or replacing it", () => {
    writeFileSync(
      TEST_PID_FILE,
      JSON.stringify({
        pid: process.pid,
        startedAt: new Date().toISOString(),
      }),
    );

    const result = acquireProcessLock(TEST_PID_FILE, { killAlive: false });
    expect(result.acquired).toBe(true);
    expect(result.killedStale).toBe(false);

    writeFileSync(
      TEST_PID_FILE,
      JSON.stringify({
        pid: 1,
        startedAt: new Date().toISOString(),
      }),
    );

    const refused = acquireProcessLock(TEST_PID_FILE, { killAlive: false });
    expect(refused.acquired).toBe(false);
    expect(refused.killedStale).toBe(false);
    expect(refused.stalePid).toBe(1);

    const content = readFileSync(TEST_PID_FILE, "utf-8");
    const data = JSON.parse(content);
    expect(data.pid).toBe(1);
  });

  it.if(nativeStart)("persists its own exact kernel start time when it takes the lock", () => {
    acquireProcessLock(TEST_PID_FILE);
    const lock = JSON.parse(readFileSync(TEST_PID_FILE, "utf-8"));
    // Independent reference: this process started before the test ran.
    const nowUs = Date.now() * 1000;
    const uptimeUs = Math.ceil(process.uptime() * 1e6);
    expect(Number.isSafeInteger(lock.processStartUs)).toBe(true);
    expect(lock.processStartUs).toBeLessThanOrEqual(nowUs);
    expect(Math.abs(nowUs - uptimeUs - lock.processStartUs)).toBeLessThan(1_000_000);
    expect(readProcessStartUs(process.pid)).toBe(lock.processStartUs);
  });

  it.if(nativeStart)("reads a fixture's start time inside its spawn bracket, null once it is gone", async () => {
    const { child, beforeMs, afterMs } = spawnSleeper();
    expectStartInside(readProcessStartUs(child.pid)!, beforeMs, afterMs);
    child.kill("SIGKILL");
    await child.exited;
    expect(readProcessStartUs(child.pid)).toBeNull();
  });

  it("does not SIGTERM an unrelated process whose argv names mcp-server-daemon.ts", async () => {
    const { child } = spawnSleeper([
      "bun",
      "-e",
      "await Bun.sleep(3_600_000)",
      "mcp-server-daemon.ts",
    ]);
    // R1 killed exactly this: its start second, written as a lock.
    writeFileSync(
      TEST_PID_FILE,
      JSON.stringify({ pid: child.pid, startedAt: new Date().toISOString() }),
    );
    const result = acquireProcessLock(TEST_PID_FILE);
    expect(result).toEqual({ acquired: true, killedStale: false, stalePid: child.pid });
    expect(isProcessAlive(child.pid)).toBe(true);
    expect(child.exitCode).toBeNull();
    expect(JSON.parse(readFileSync(TEST_PID_FILE, "utf-8")).pid).toBe(process.pid);
  });

  it("does not SIGTERM a process newer than the lock's recorded generation", () => {
    const { child, beforeMs } = spawnSleeper();
    writeFileSync(
      TEST_PID_FILE,
      JSON.stringify({
        pid: child.pid,
        startedAt: new Date(beforeMs).toISOString(),
        // One microsecond before the spawn bracket: an older generation.
        processStartUs: beforeMs * 1000 - 1,
      }),
    );
    const kill = spyOn(process, "kill");
    let result;
    try {
      result = acquireProcessLock(TEST_PID_FILE);
      expect(sigtermsTo(kill, child.pid)).toBe(0);
    } finally {
      kill.mockRestore();
    }
    expect(result).toEqual({ acquired: true, killedStale: false, stalePid: child.pid });
    expect(isProcessAlive(child.pid)).toBe(true);
  });

  it("does not SIGTERM a genuine owner whose lock is legacy-format", async () => {
    const { child, lock } = await spawnLockOwner({ relative: false });
    writeFileSync(
      TEST_PID_FILE,
      JSON.stringify({ pid: lock.pid, startedAt: lock.startedAt }),
    );
    const result = acquireProcessLock(TEST_PID_FILE);
    expect(result).toEqual({ acquired: true, killedStale: false, stalePid: child.pid });
    expect(isProcessAlive(child.pid)).toBe(true);
    expect(child.exitCode).toBeNull();
  });

  it("does not SIGTERM when the start time is unknown", async () => {
    const { child } = await spawnLockOwner({ relative: false });
    const result = acquireProcessLock(TEST_PID_FILE, {
      readProcessStartUs: () => null,
    });
    expect(result).toEqual({ acquired: true, killedStale: false, stalePid: child.pid });
    expect(isProcessAlive(child.pid)).toBe(true);
  });

  it("reclaims a synthetic generation that matches on both reads (decision control)", async () => {
    const { child } = spawnSleeper();
    writeSyntheticLock(child.pid);
    const result = acquireProcessLock(TEST_PID_FILE, {
      readProcessStartUs: () => SYNTHETIC_START_US,
    });
    expect(result).toEqual({ acquired: true, killedStale: true, stalePid: child.pid });
    await child.exited;
    expect(child.signalCode).toBe("SIGTERM");
  });

  it("does not SIGTERM when the start time changes before the signal", () => {
    const { child } = spawnSleeper();
    writeSyntheticLock(child.pid);
    let reads = 0;
    const result = acquireProcessLock(TEST_PID_FILE, {
      readProcessStartUs: () => {
        reads += 1;
        return reads === 1 ? SYNTHETIC_START_US : SYNTHETIC_START_US + 1;
      },
    });
    expect(reads).toBe(2);
    expect(result).toEqual({ acquired: true, killedStale: false, stalePid: child.pid });
    expect(isProcessAlive(child.pid)).toBe(true);
  });

  it("does not SIGTERM when the identity observation is too old", () => {
    const { child } = spawnSleeper();
    writeSyntheticLock(child.pid);
    const clock = [0, 251];
    const result = acquireProcessLock(TEST_PID_FILE, {
      readProcessStartUs: () => SYNTHETIC_START_US,
      monotonicNowMs: () => clock.shift() ?? 251,
    });
    expect(clock).toEqual([]);
    expect(result).toEqual({ acquired: true, killedStale: false, stalePid: child.pid });
    expect(isProcessAlive(child.pid)).toBe(true);
  });

  it("without a native reader (non-Darwin), persists no generation and never signals", async () => {
    const { child } = spawnSleeper();
    const dir = fixtureDir();
    const shim = join(dir, "force-linux.ts");
    writeFileSync(shim, `Object.defineProperty(process, "platform", { value: "linux" });\n`);
    const own = join(dir, "own.pid");
    const probe = join(dir, "probe.ts");
    writeFileSync(
      probe,
      `import { acquireProcessLock, readProcessStartUs } from ${JSON.stringify(PROCESS_LOCK_MODULE)};\n` +
        `import { readFileSync } from "fs";\n` +
        `const [own, victimLock, victimPid] = process.argv.slice(2);\n` +
        `acquireProcessLock(own);\n` +
        `const reclaim = acquireProcessLock(victimLock);\n` +
        `console.log(JSON.stringify({ platform: process.platform, reader: readProcessStartUs(process.pid),` +
        ` ownLock: JSON.parse(readFileSync(own, "utf-8")), reclaim, victimPid: Number(victimPid) }));\n`,
    );
    writeSyntheticLock(child.pid);
    const run = Bun.spawnSync(
      ["bun", "--preload", shim, probe, own, TEST_PID_FILE, String(child.pid)],
      { cwd: dir, env: process.env, stdout: "pipe", stderr: "pipe" },
    );
    expect(run.exitCode).toBe(0);
    const out = JSON.parse(run.stdout.toString().trim().split("\n").pop()!);
    expect(out.platform).toBe("linux");
    expect(out.reader).toBeNull();
    expect(Object.keys(out.ownLock).sort()).toEqual(["pid", "startedAt"]);
    expect(out.reclaim).toEqual({ acquired: true, killedStale: false, stalePid: child.pid });
    expect(isProcessAlive(child.pid)).toBe(true);
    expect(child.exitCode).toBeNull();
  });

  it.if(nativeStart)("reclaims a genuine orphan whose lock carries its exact start", async () => {
    const { child, lock, beforeMs, afterMs } = await spawnLockOwner({ relative: false });
    expectStartInside(lock.processStartUs, beforeMs, afterMs);
    const result = acquireProcessLock(TEST_PID_FILE);
    expect(result).toEqual({ acquired: true, killedStale: true, stalePid: child.pid });
    await child.exited;
    expect(child.signalCode).toBe("SIGTERM");
    expect(JSON.parse(readFileSync(TEST_PID_FILE, "utf-8")).pid).toBe(process.pid);
  });

  it.if(nativeStart)("reclaims a genuine orphan launched by a relative entrypoint (bun daemon.ts)", async () => {
    const { child, lock, beforeMs, afterMs } = await spawnLockOwner({ relative: true });
    expectStartInside(lock.processStartUs, beforeMs, afterMs);
    const result = acquireProcessLock(TEST_PID_FILE);
    expect(result).toEqual({ acquired: true, killedStale: true, stalePid: child.pid });
    await child.exited;
    expect(child.signalCode).toBe("SIGTERM");
  });
});
