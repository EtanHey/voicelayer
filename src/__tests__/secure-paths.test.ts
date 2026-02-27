import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import { existsSync, writeFileSync, unlinkSync } from "fs";

describe("secure session paths", () => {
  // Import fresh each time to get the session token
  let paths: typeof import("../paths");

  beforeEach(async () => {
    paths = await import("../paths");
  });

  afterEach(() => {
    // Clean up any stop files
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

  it("SOCKET_PATH contains session token", () => {
    expect(paths.SOCKET_PATH).toContain(paths.SESSION_TOKEN);
    expect(paths.SOCKET_PATH).toContain("voicelayer-");
    expect(paths.SOCKET_PATH).toEndWith(".sock");
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
    // Clean up
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
    // Writing to the old /tmp/voicelayer-stop should NOT trigger stop
    const oldPath = "/tmp/voicelayer-stop";
    try {
      writeFileSync(oldPath, "spoofed stop");
      // hasStopSignal should only check the tokenized path
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

describe("socket discovery file", () => {
  let paths: typeof import("../paths");

  beforeEach(async () => {
    paths = await import("../paths");
  });

  it("DISCOVERY_FILE is at well-known location", () => {
    expect(paths.DISCOVERY_FILE).toBe("/tmp/voicelayer-session.json");
  });

  it("writeDiscoveryFile creates JSON with socket path and token", () => {
    paths.writeDiscoveryFile();
    expect(existsSync(paths.DISCOVERY_FILE)).toBe(true);
    const content = JSON.parse(
      require("fs").readFileSync(paths.DISCOVERY_FILE, "utf-8"),
    );
    expect(content.socketPath).toBe(paths.SOCKET_PATH);
    expect(content.stopFile).toBe(paths.STOP_FILE);
    expect(content.sessionToken).toBe(paths.SESSION_TOKEN);
    expect(content.pid).toBe(process.pid);
    // Clean up
    try {
      unlinkSync(paths.DISCOVERY_FILE);
    } catch {}
  });

  it("removeDiscoveryFile cleans up", () => {
    paths.writeDiscoveryFile();
    expect(existsSync(paths.DISCOVERY_FILE)).toBe(true);
    paths.removeDiscoveryFile();
    expect(existsSync(paths.DISCOVERY_FILE)).toBe(false);
  });
});
