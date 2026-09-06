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
    expect(paths.STOP_FILE).toContain("stop-");
  });

  // AIDEV-NOTE: R-014 — SOCKET_PATH is frozen from this process's env at module
  // load, and the test preload redirects it. The invariant that matters is the
  // DEFAULT: a fixed well-known path with no session token in it.
  it("SOCKET_PATH defaults to fixed well-known path (no session token)", () => {
    expect(paths.getVoiceBarSocketPath({} as NodeJS.ProcessEnv)).toBe(
      "/tmp/voicelayer.sock",
    );
    expect(paths.SOCKET_PATH).toBe(paths.getVoiceBarSocketPath());
    // Should NOT contain session token — fixed path for VoiceBar server
    expect(paths.SOCKET_PATH).not.toContain(paths.SESSION_TOKEN);
  });

  it("getVoiceBarSocketPath allows test isolation via env override", () => {
    expect(
      paths.getVoiceBarSocketPath({
        QA_VOICE_SOCKET_PATH: "/tmp/voicelayer-private-test.sock",
      } as NodeJS.ProcessEnv),
    ).toBe("/tmp/voicelayer-private-test.sock");
    expect(paths.getVoiceBarSocketPath({} as NodeJS.ProcessEnv)).toBe(
      "/tmp/voicelayer.sock",
    );
  });

  it("reports default socket paths from centralized override state", () => {
    expect(paths.isDefaultVoiceBarSocketPath({} as NodeJS.ProcessEnv)).toBe(true);
    expect(paths.isDefaultMcpSocketPath({} as NodeJS.ProcessEnv)).toBe(true);
    expect(
      paths.isDefaultVoiceBarSocketPath({
        QA_VOICE_SOCKET_PATH: "/tmp/voicelayer-private-test.sock",
      } as NodeJS.ProcessEnv),
    ).toBe(false);
    expect(
      paths.isDefaultMcpSocketPath({
        QA_VOICE_MCP_SOCKET_PATH: "/tmp/voicelayer-mcp-private-test.sock",
      } as NodeJS.ProcessEnv),
    ).toBe(false);
  });

  it("returns MCP socket override for client hello without duplicating env lookup", () => {
    expect(paths.getMcpSocketOverridePath({} as NodeJS.ProcessEnv)).toBeNull();
    expect(
      paths.getMcpSocketOverridePath({
        QA_VOICE_MCP_SOCKET_PATH: "/tmp/voicelayer-mcp-private-test.sock",
      } as NodeJS.ProcessEnv),
    ).toBe("/tmp/voicelayer-mcp-private-test.sock");
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
