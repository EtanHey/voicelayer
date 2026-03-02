import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import { existsSync, writeFileSync, unlinkSync } from "fs";

describe("secure session paths", () => {
  let paths: typeof import("../paths");

  beforeEach(async () => {
    paths = await import("../paths");
  });

  afterEach(() => {
    if (existsSync(paths.STOP_FILE)) {
      try {
        unlinkSync(paths.STOP_FILE);
      } catch {}
    }
  });

  it("SESSION_TOKEN is a random hex string", () => {
    expect(paths.SESSION_TOKEN).toBeDefined();
    expect(typeof paths.SESSION_TOKEN).toBe("string");
    // At least 16 hex chars (8 bytes)
    expect(paths.SESSION_TOKEN.length).toBeGreaterThanOrEqual(16);
    expect(/^[0-9a-f]+$/.test(paths.SESSION_TOKEN)).toBe(true);
  });

  it("STOP_FILE contains session token", () => {
    expect(paths.STOP_FILE).toContain(paths.SESSION_TOKEN);
    expect(paths.STOP_FILE).toContain("voicelayer-stop-");
  });

  it("SOCKET_PATH is fixed well-known path (no session token)", () => {
    expect(paths.SOCKET_PATH).toBe("/tmp/voicelayer.sock");
    // Should NOT contain session token — fixed path for FlowBar server
    expect(paths.SOCKET_PATH).not.toContain(paths.SESSION_TOKEN);
  });

  it("LOCK_FILE contains session token", () => {
    expect(paths.LOCK_FILE).toContain(paths.SESSION_TOKEN);
  });
});

describe("stop signal with session token", () => {
  let sessionBooking: typeof import("../session-booking");
  let paths: typeof import("../paths");

  beforeEach(async () => {
    paths = await import("../paths");
    sessionBooking = await import("../session-booking");
    if (existsSync(paths.STOP_FILE)) {
      try {
        unlinkSync(paths.STOP_FILE);
      } catch {}
    }
  });

  afterEach(() => {
    if (existsSync(paths.STOP_FILE)) {
      try {
        unlinkSync(paths.STOP_FILE);
      } catch {}
    }
  });

  it("detects stop signal at tokenized path", () => {
    expect(sessionBooking.hasStopSignal()).toBe(false);
    writeFileSync(paths.STOP_FILE, "stop");
    expect(sessionBooking.hasStopSignal()).toBe(true);
  });

  it("rejects stop signal at old predictable path", () => {
    const oldPath = "/tmp/voicelayer-stop";
    try {
      writeFileSync(oldPath, "spoofed stop");
      expect(sessionBooking.hasStopSignal()).toBe(false);
    } finally {
      try {
        unlinkSync(oldPath);
      } catch {}
    }
  });

  it("clears tokenized stop signal", () => {
    writeFileSync(paths.STOP_FILE, "stop");
    sessionBooking.clearStopSignal();
    expect(existsSync(paths.STOP_FILE)).toBe(false);
  });
});
