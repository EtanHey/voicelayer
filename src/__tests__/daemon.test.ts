/**
 * Tests for standalone daemon (daemon.ts) — VoiceLayer without MCP.
 *
 * Verifies:
 * - Daemon uses separate PID file from MCP (coexistence)
 * - Process lock accepts configurable PID file path
 * - Daemon has zero MCP SDK imports
 * - CLI integration (voicelayer serve)
 */
import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import { existsSync, readFileSync, unlinkSync } from "fs";
import {
  acquireProcessLock,
  releaseProcessLock,
  MCP_PID_FILE,
} from "../process-lock";
import { DAEMON_PID_FILE } from "../paths";
import { createShutdownHandler, getServeSocketPath } from "../daemon";

// --- Helpers ---

function cleanFile(path: string) {
  if (existsSync(path)) {
    try {
      unlinkSync(path);
    } catch {}
  }
}

// --- Tests ---

describe("daemon PID coexistence", () => {
  beforeEach(() => {
    cleanFile(DAEMON_PID_FILE);
    cleanFile(MCP_PID_FILE);
  });

  afterEach(() => {
    releaseProcessLock(DAEMON_PID_FILE);
    releaseProcessLock(MCP_PID_FILE);
    cleanFile(DAEMON_PID_FILE);
    cleanFile(MCP_PID_FILE);
  });

  it("DAEMON_PID_FILE is different from MCP_PID_FILE", () => {
    expect(DAEMON_PID_FILE).not.toBe(MCP_PID_FILE);
    expect(DAEMON_PID_FILE).toContain("voicelayer-daemon");
    expect(MCP_PID_FILE).toContain("voicelayer-mcp");
  });

  it("acquires daemon lock at custom PID path", () => {
    const result = acquireProcessLock(DAEMON_PID_FILE);
    expect(result.acquired).toBe(true);
    expect(existsSync(DAEMON_PID_FILE)).toBe(true);

    const data = JSON.parse(readFileSync(DAEMON_PID_FILE, "utf-8"));
    expect(data.pid).toBe(process.pid);
  });

  it("daemon and MCP locks are independent", () => {
    const daemonResult = acquireProcessLock(DAEMON_PID_FILE);
    const mcpResult = acquireProcessLock(MCP_PID_FILE);

    expect(daemonResult.acquired).toBe(true);
    expect(mcpResult.acquired).toBe(true);

    // Both PID files exist simultaneously
    expect(existsSync(DAEMON_PID_FILE)).toBe(true);
    expect(existsSync(MCP_PID_FILE)).toBe(true);

    // Both have our PID
    const daemonData = JSON.parse(readFileSync(DAEMON_PID_FILE, "utf-8"));
    const mcpData = JSON.parse(readFileSync(MCP_PID_FILE, "utf-8"));
    expect(daemonData.pid).toBe(process.pid);
    expect(mcpData.pid).toBe(process.pid);
  });

  it("releases daemon lock without affecting MCP lock", () => {
    acquireProcessLock(DAEMON_PID_FILE);
    acquireProcessLock(MCP_PID_FILE);

    releaseProcessLock(DAEMON_PID_FILE);

    expect(existsSync(DAEMON_PID_FILE)).toBe(false);
    expect(existsSync(MCP_PID_FILE)).toBe(true); // MCP lock untouched
  });

  it("releases MCP lock without affecting daemon lock", () => {
    acquireProcessLock(DAEMON_PID_FILE);
    acquireProcessLock(MCP_PID_FILE);

    releaseProcessLock(MCP_PID_FILE);

    expect(existsSync(MCP_PID_FILE)).toBe(false);
    expect(existsSync(DAEMON_PID_FILE)).toBe(true); // Daemon lock untouched
  });

  it("default lock path is MCP (backward compat)", () => {
    const result = acquireProcessLock();
    expect(result.acquired).toBe(true);
    expect(existsSync(MCP_PID_FILE)).toBe(true);

    releaseProcessLock();
    expect(existsSync(MCP_PID_FILE)).toBe(false);
  });
});

describe("daemon has no MCP imports", () => {
  it("daemon.ts has no MCP import statements", async () => {
    const daemonSrc = await Bun.file("src/daemon.ts").text();
    // Extract only import lines (not comments)
    const importLines = daemonSrc
      .split("\n")
      .filter((line) => line.trimStart().startsWith("import "));

    const joined = importLines.join("\n");
    expect(joined).not.toContain("@modelcontextprotocol");
    expect(joined).not.toContain("mcp-daemon");
    expect(joined).not.toContain("createMcpDaemon");
    expect(joined).not.toContain("./mcp-server");
    expect(joined).not.toContain("./mcp-handler");
    expect(joined).not.toContain("./mcp-tools");
  });
});

describe("daemon shutdown", () => {
  it("releases the PID lock and disconnects exactly once on repeated shutdown signals", () => {
    const calls: string[] = [];
    const shutdown = createShutdownHandler({
      disconnect: () => calls.push("disconnect"),
      releaseLock: () => calls.push("releaseLock"),
      exit: (code) => calls.push(`exit:${code}`),
    });

    shutdown();
    shutdown();

    expect(calls).toEqual(["disconnect", "releaseLock", "exit:0"]);
  });
});

describe("daemon socket path", () => {
  it("defaults to VoiceBar's well-known socket", () => {
    const saved = process.env.QA_VOICE_SOCKET_PATH;
    delete process.env.QA_VOICE_SOCKET_PATH;
    try {
      expect(getServeSocketPath()).toBeUndefined();
    } finally {
      if (saved) process.env.QA_VOICE_SOCKET_PATH = saved;
    }
  });

  it("allows overriding the socket path for isolated verification", () => {
    const saved = process.env.QA_VOICE_SOCKET_PATH;
    process.env.QA_VOICE_SOCKET_PATH = "/tmp/voicelayer-test.sock";
    try {
      expect(getServeSocketPath()).toBe("/tmp/voicelayer-test.sock");
    } finally {
      if (saved) process.env.QA_VOICE_SOCKET_PATH = saved;
      else delete process.env.QA_VOICE_SOCKET_PATH;
    }
  });
});

describe("CLI integration", () => {
  it("voicelayer.sh includes serve command", async () => {
    const cliSrc = await Bun.file("src/cli/voicelayer.sh").text();
    expect(cliSrc).toContain("serve)");
    expect(cliSrc).toContain("daemon.ts");
  });

  it("voicelayer.sh resolves flow-bar only inside the bar command", async () => {
    const cliSrc = await Bun.file("src/cli/voicelayer.sh").text();
    expect(cliSrc).not.toMatch(
      /SCRIPT_DIR=.*\n\nFLOW_BAR_DIR=.*\n\ncase/s,
    );
    expect(cliSrc).toMatch(
      /bar\)\n[\s\S]*FLOW_BAR_DIR=.*\n[\s\S]*swift build/s,
    );
  });

  it("voicelayer.sh help includes serve command", async () => {
    const cliSrc = await Bun.file("src/cli/voicelayer.sh").text();
    expect(cliSrc).toContain("serve");
    // Help text should mention standalone
    expect(cliSrc).toMatch(/serve.*[Ss]tandalone|serve.*daemon|serve.*without/);
  });
});
