import { describe, it, expect, beforeEach, afterEach, spyOn } from "bun:test";
import {
  chmodSync,
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
} from "../process-lock";

const TEST_PID_FILE = join(
  TEST_TMP,
  `voicelayer-process-lock-test-${process.pid}.pid`,
);

const fixtureChildren: Array<ReturnType<typeof Bun.spawn>> = [];

function cleanPidFile() {
  if (existsSync(TEST_PID_FILE)) {
    try {
      unlinkSync(TEST_PID_FILE);
    } catch {}
  }
}

function reapFixtures() {
  while (fixtureChildren.length > 0) {
    const child = fixtureChildren.pop();
    if (!child?.pid) continue;
    try {
      process.kill(child.pid, "SIGKILL");
    } catch {}
    try {
      child.kill();
    } catch {}
  }
}

function processStartIso(pid: number): string {
  const result = Bun.spawnSync(["ps", "-o", "lstart=", "-p", String(pid)], {
    stdout: "pipe",
    stderr: "ignore",
    env: { ...process.env, LC_ALL: "C", LANG: "C" },
  });
  const startedAt = Date.parse(result.stdout.toString().trim());
  if (!Number.isFinite(startedAt)) {
    throw new Error(`could not read lstart for pid ${pid}`);
  }
  return new Date(startedAt).toISOString();
}

function spawnUnrelatedFixture(): ReturnType<typeof Bun.spawn> {
  const child = Bun.spawn(["/bin/sleep", "3600"], {
    stdout: "ignore",
    stderr: "ignore",
    env: process.env,
  });
  if (!child.pid) throw new Error("unrelated fixture failed to start");
  fixtureChildren.push(child);
  return child;
}

function spawnDaemonNamedFixture(): {
  child: ReturnType<typeof Bun.spawn>;
  scriptPath: string;
} {
  const dir = join(TEST_TMP, `lock1-daemon-fixture-${process.pid}-${Date.now()}`);
  mkdirSync(dir, { recursive: true });
  const scriptPath = join(dir, "mcp-server-daemon.js");
  writeFileSync(
    scriptPath,
    "#!/usr/bin/env bun\nawait Bun.sleep(3_600_000);\n",
  );
  chmodSync(scriptPath, 0o755);
  const child = Bun.spawn(["bun", "run", scriptPath], {
    stdout: "ignore",
    stderr: "ignore",
    env: process.env,
  });
  if (!child.pid) throw new Error("daemon-named fixture failed to start");
  fixtureChildren.push(child);
  return { child, scriptPath };
}

describe("process lock", () => {
  beforeEach(() => {
    cleanPidFile();
    reapFixtures();
  });
  afterEach(() => {
    reapFixtures();
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

  it("claims without SIGTERM when an alive PID is not a VoiceLayer daemon (e.g. PID 1)", () => {
    // PID 1 is alive but never our daemon identity — claim without signalling.
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
      expect(kill.mock.calls.some((call) => call[1] === "SIGTERM")).toBe(false);
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

  it("does not SIGTERM a reused PID with a mismatched start time; claims the lock", () => {
    const child = spawnUnrelatedFixture();
    const pid = child.pid!;
    expect(isProcessAlive(pid)).toBe(true);

    writeFileSync(
      TEST_PID_FILE,
      JSON.stringify({
        pid,
        // Stale lock from a prior process that occupied this PID.
        startedAt: "2020-01-01T00:00:00.000Z",
      }),
    );

    const kill = spyOn(process, "kill");
    let result;
    try {
      result = acquireProcessLock(TEST_PID_FILE);
      expect(
        kill.mock.calls.some(
          (call) => call[0] === pid && call[1] === "SIGTERM",
        ),
      ).toBe(false);
    } finally {
      kill.mockRestore();
    }

    expect(result.acquired).toBe(true);
    expect(result.killedStale).toBe(false);
    expect(result.stalePid).toBe(pid);
    expect(isProcessAlive(pid)).toBe(true);

    const content = JSON.parse(readFileSync(TEST_PID_FILE, "utf-8"));
    expect(content.pid).toBe(process.pid);
  });

  it("still SIGTERMs a genuine orphan with matching start time and daemon command", () => {
    const { child, scriptPath } = spawnDaemonNamedFixture();
    const pid = child.pid!;
    expect(isProcessAlive(pid)).toBe(true);

    writeFileSync(
      TEST_PID_FILE,
      JSON.stringify({
        pid,
        startedAt: processStartIso(pid),
      }),
    );

    const kill = spyOn(process, "kill");
    let result;
    try {
      result = acquireProcessLock(TEST_PID_FILE);
      expect(
        kill.mock.calls.some(
          (call) => call[0] === pid && call[1] === "SIGTERM",
        ),
      ).toBe(true);
    } finally {
      kill.mockRestore();
    }

    expect(result.acquired).toBe(true);
    expect(result.killedStale).toBe(true);
    expect(result.stalePid).toBe(pid);

    const content = JSON.parse(readFileSync(TEST_PID_FILE, "utf-8"));
    expect(content.pid).toBe(process.pid);

    try {
      rmSync(join(scriptPath, ".."), { recursive: true, force: true });
    } catch {}
  });

  it("does not SIGTERM when process start time is unknown; claims the lock", () => {
    const { child, scriptPath } = spawnDaemonNamedFixture();
    const pid = child.pid!;
    expect(isProcessAlive(pid)).toBe(true);

    writeFileSync(
      TEST_PID_FILE,
      JSON.stringify({
        pid,
        startedAt: processStartIso(pid),
      }),
    );

    const kill = spyOn(process, "kill");
    let result;
    try {
      result = acquireProcessLock(TEST_PID_FILE, {
        readProcessStartTimeMs: () => null,
      });
      expect(
        kill.mock.calls.some(
          (call) => call[0] === pid && call[1] === "SIGTERM",
        ),
      ).toBe(false);
    } finally {
      kill.mockRestore();
    }

    expect(result.acquired).toBe(true);
    expect(result.killedStale).toBe(false);
    expect(isProcessAlive(pid)).toBe(true);

    try {
      rmSync(join(scriptPath, ".."), { recursive: true, force: true });
    } catch {}
  });
});
