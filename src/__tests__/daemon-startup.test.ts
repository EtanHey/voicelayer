import { describe, expect, test } from "bun:test";
import {
  classifyPidOwnerCommand,
  resolveMcpPidOwnerStartup,
  resolveMcpSocketStartup,
} from "../daemon-startup";

describe("MCP daemon startup socket ownership", () => {
  test("stands down with exit 0 when another healthy daemon keeps the socket live", async () => {
    const logLines: string[] = [];
    const liveChecks: string[] = [];

    const decision = await resolveMcpSocketStartup({
      socketPath: "/tmp/voicelayer-isolated-contention.sock",
      isSocketLive: async (socketPath) => {
        liveChecks.push(socketPath);
        return true;
      },
      sleep: async () => {},
      log: (message) => logLines.push(message),
    });

    expect(decision).toEqual({ action: "stand_down", exitCode: 0 });
    expect(liveChecks.length).toBeGreaterThan(1);
    expect(logLines.join("\n")).toContain("standing down");
  });

  test("continues startup when the socket clears during validation", async () => {
    let checks = 0;

    const decision = await resolveMcpSocketStartup({
      socketPath: "/tmp/voicelayer-isolated-clears.sock",
      isSocketLive: async () => {
        checks += 1;
        return checks === 1;
      },
      sleep: async () => {},
      log: () => {},
    });

    expect(decision).toEqual({ action: "continue" });
    expect(checks).toBe(2);
  });

  test("stands down for a live PID owner once its socket becomes live", async () => {
    let checks = 0;

    const decision = await resolveMcpPidOwnerStartup({
      ownerPid: 1234,
      socketPath: "/tmp/voicelayer-owner-live.sock",
      isSocketLive: async () => {
        checks += 1;
        return checks === 3;
      },
      readProcessCommand: () => "bun run src/mcp-server-daemon.ts",
      sleep: async () => {},
      log: () => {},
    });

    expect(decision).toEqual({
      action: "stand_down",
      reason: "socket_live",
      ownerCommandKind: "mcp-daemon",
    });
  });

  test("stands down for a starting daemon owner even before the socket is live", async () => {
    const decision = await resolveMcpPidOwnerStartup({
      ownerPid: 1234,
      socketPath: "/tmp/voicelayer-owner-starting.sock",
      isSocketLive: async () => false,
      readProcessCommand: () =>
        "/Users/me/.bun/bin/bun run /Applications/VoiceBar.app/Contents/Resources/src/mcp-server-daemon.ts",
      sleep: async () => {},
      log: () => {},
    });

    expect(decision).toEqual({
      action: "stand_down",
      reason: "daemon_starting",
      ownerCommandKind: "mcp-daemon",
    });
  });

  test("reclaims legacy or unrelated live PID owners when no socket becomes live", async () => {
    const decision = await resolveMcpPidOwnerStartup({
      ownerPid: 1234,
      socketPath: "/tmp/voicelayer-owner-legacy.sock",
      isSocketLive: async () => false,
      readProcessCommand: () => "bun /Users/me/.bun/bin/voicelayer-mcp",
      sleep: async () => {},
      log: () => {},
    });

    expect(decision).toEqual({
      action: "reclaim",
      reason: "no_socket_live",
      ownerCommandKind: "legacy-or-unrelated",
    });
  });

  test("reclaims unreadable live PID owners when no socket becomes live", async () => {
    const decision = await resolveMcpPidOwnerStartup({
      ownerPid: 1234,
      socketPath: "/tmp/voicelayer-owner-unknown.sock",
      isSocketLive: async () => false,
      readProcessCommand: () => null,
      sleep: async () => {},
      log: () => {},
    });

    expect(decision).toEqual({
      action: "reclaim",
      reason: "no_socket_live",
      ownerCommandKind: "unknown",
    });
  });

  test("classifies only mcp-server-daemon commands as starting daemon owners", () => {
    expect(classifyPidOwnerCommand("bun run src/mcp-server-daemon.ts")).toBe(
      "mcp-daemon",
    );
    expect(classifyPidOwnerCommand("bun run src/mcp-server.ts")).toBe(
      "legacy-or-unrelated",
    );
    expect(classifyPidOwnerCommand(null)).toBe("unknown");
  });
});
