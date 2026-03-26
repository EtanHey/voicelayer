import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import { existsSync, writeFileSync, unlinkSync, readFileSync } from "fs";

import {
  acquireProcessLock,
  releaseProcessLock,
  isProcessAlive,
  MCP_PID_FILE,
} from "../process-lock";

function cleanPidFile() {
  if (existsSync(MCP_PID_FILE)) {
    try {
      unlinkSync(MCP_PID_FILE);
    } catch {}
  }
}

describe("process lock", () => {
  beforeEach(cleanPidFile);
  afterEach(cleanPidFile);

  it("acquires lock when no PID file exists", () => {
    const result = acquireProcessLock();
    expect(result.acquired).toBe(true);
    expect(result.killedStale).toBe(false);
    expect(existsSync(MCP_PID_FILE)).toBe(true);

    const content = readFileSync(MCP_PID_FILE, "utf-8");
    const data = JSON.parse(content);
    expect(data.pid).toBe(process.pid);
    expect(typeof data.startedAt).toBe("string");
  });

  it("acquires lock after cleaning stale PID file (dead process)", () => {
    // Write a PID file with a definitely-dead PID
    writeFileSync(
      MCP_PID_FILE,
      JSON.stringify({
        pid: 99999999,
        startedAt: new Date().toISOString(),
      }),
    );

    const result = acquireProcessLock();
    expect(result.acquired).toBe(true);
    // killedStale is false — the process was already dead, we didn't kill it
    expect(result.killedStale).toBe(false);
    expect(result.stalePid).toBe(99999999);

    const content = readFileSync(MCP_PID_FILE, "utf-8");
    const data = JSON.parse(content);
    expect(data.pid).toBe(process.pid);
  });

  it("acquires lock when PID file contains corrupt data", () => {
    writeFileSync(MCP_PID_FILE, "not json at all");
    const result = acquireProcessLock();
    expect(result.acquired).toBe(true);
  });

  it("acquires lock when PID file is empty", () => {
    writeFileSync(MCP_PID_FILE, "");
    const result = acquireProcessLock();
    expect(result.acquired).toBe(true);
  });

  it("releases lock by removing PID file", () => {
    acquireProcessLock();
    expect(existsSync(MCP_PID_FILE)).toBe(true);

    releaseProcessLock();
    expect(existsSync(MCP_PID_FILE)).toBe(false);
  });

  it("release is idempotent (no error if no file)", () => {
    expect(() => releaseProcessLock()).not.toThrow();
  });

  it("detects living process (our own PID)", () => {
    expect(isProcessAlive(process.pid)).toBe(true);
  });

  it("detects dead process (impossible PID)", () => {
    expect(isProcessAlive(99999999)).toBe(false);
  });

  it("handles PID file with valid JSON but missing pid field", () => {
    writeFileSync(MCP_PID_FILE, JSON.stringify({ startedAt: "now" }));
    const result = acquireProcessLock();
    expect(result.acquired).toBe(true);
  });

  it("attempts SIGTERM on alive stale process before claiming lock", () => {
    // PID 1 (init/launchd) is always alive but SIGTERM fails with EPERM
    writeFileSync(
      MCP_PID_FILE,
      JSON.stringify({
        pid: 1,
        startedAt: new Date().toISOString(),
      }),
    );

    const result = acquireProcessLock();
    // Should still acquire — PID 1 can't be killed but we claim the lock anyway
    expect(result.acquired).toBe(true);
    // killedStale is false because SIGTERM threw EPERM
    expect(result.killedStale).toBe(false);
    expect(result.stalePid).toBe(1);
  });
});
