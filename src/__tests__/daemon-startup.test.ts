import { describe, expect, test } from "bun:test";
import { resolveMcpSocketStartup } from "../daemon-startup";

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
});
