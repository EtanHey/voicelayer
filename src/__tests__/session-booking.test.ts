import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import { existsSync, writeFileSync, unlinkSync } from "fs";
import { LOCK_FILE, STOP_FILE } from "../paths";

// Clean up before importing (module has side effects via process handlers)
function cleanFiles() {
  for (const f of [LOCK_FILE, STOP_FILE]) {
    if (existsSync(f)) {
      try {
        unlinkSync(f);
      } catch {}
    }
  }
}

import {
  bookVoiceSession,
  releaseVoiceSession,
  isVoiceBooked,
  cleanStaleLock,
  hasStopSignal,
  clearStopSignal,
} from "../session-booking";

describe("session booking", () => {
  beforeEach(cleanFiles);
  afterEach(cleanFiles);

  it("books a voice session successfully", () => {
    const result = bookVoiceSession("test-session");
    expect(result.success).toBe(true);
    expect(result.lock?.pid).toBe(process.pid);
    expect(result.lock?.sessionId).toBe("test-session");
    expect(existsSync(LOCK_FILE)).toBe(true);
  });

  it("returns already booked when same PID books again", () => {
    bookVoiceSession("first");
    const result = bookVoiceSession("second");
    expect(result.success).toBe(true);
    // Still the original booking
    expect(result.lock?.sessionId).toBe("first");
  });

  it("rejects booking when another PID owns the lock", () => {
    // Write a lock with a different PID (use PID 1 — init, always alive)
    writeFileSync(
      LOCK_FILE,
      JSON.stringify({
        pid: 1,
        sessionId: "other",
        startedAt: new Date().toISOString(),
      }),
    );
    const result = bookVoiceSession("mine");
    expect(result.success).toBe(false);
    expect(result.error).toContain("Line is busy");
  });

  it("cleans stale lock from dead PID", () => {
    // Use a PID that almost certainly doesn't exist
    writeFileSync(
      LOCK_FILE,
      JSON.stringify({
        pid: 999999,
        sessionId: "dead",
        startedAt: new Date().toISOString(),
      }),
    );
    const cleaned = cleanStaleLock();
    expect(cleaned).toBe(true);
    expect(existsSync(LOCK_FILE)).toBe(false);
  });

  it("books successfully after stale lock cleanup", () => {
    writeFileSync(
      LOCK_FILE,
      JSON.stringify({
        pid: 999999,
        sessionId: "dead",
        startedAt: new Date().toISOString(),
      }),
    );
    const result = bookVoiceSession("fresh");
    expect(result.success).toBe(true);
    expect(result.lock?.sessionId).toBe("fresh");
  });

  it("releases voice session", () => {
    bookVoiceSession("to-release");
    expect(existsSync(LOCK_FILE)).toBe(true);
    releaseVoiceSession();
    expect(existsSync(LOCK_FILE)).toBe(false);
  });

  it("does not release lock owned by another PID", () => {
    writeFileSync(
      LOCK_FILE,
      JSON.stringify({
        pid: 1,
        sessionId: "other",
        startedAt: new Date().toISOString(),
      }),
    );
    releaseVoiceSession();
    // Lock should still exist — not ours to release
    expect(existsSync(LOCK_FILE)).toBe(true);
  });

  it("reports booking status correctly", () => {
    const status1 = isVoiceBooked();
    expect(status1.booked).toBe(false);
    expect(status1.ownedByUs).toBe(false);

    bookVoiceSession("mine");
    const status2 = isVoiceBooked();
    expect(status2.booked).toBe(true);
    expect(status2.ownedByUs).toBe(true);
    expect(status2.owner?.sessionId).toBe("mine");
  });

  it("uses default session ID when none provided", () => {
    const result = bookVoiceSession();
    expect(result.success).toBe(true);
    expect(result.lock?.sessionId).toBe(`mcp-${process.pid}`);
  });
});

describe("stop signal", () => {
  beforeEach(cleanFiles);
  afterEach(cleanFiles);

  it("detects stop signal file", () => {
    expect(hasStopSignal()).toBe(false);
    writeFileSync(STOP_FILE, "");
    expect(hasStopSignal()).toBe(true);
  });

  it("clears stop signal", () => {
    writeFileSync(STOP_FILE, "");
    clearStopSignal();
    expect(hasStopSignal()).toBe(false);
  });

  it("clearStopSignal is safe when no file exists", () => {
    expect(() => clearStopSignal()).not.toThrow();
  });
});
