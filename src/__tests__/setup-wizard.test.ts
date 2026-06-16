import { describe, expect, test } from "bun:test";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "fs";
import { tmpdir } from "os";
import { dirname, join } from "path";
import {
  detectAgentClis,
  getSetupCommandPlan,
  getTccGrantSteps,
  loadRememberedAgent,
  rememberAgent,
  resolveAgentConfigPath,
  wireAgentMcpConfig,
  type AgentId,
} from "../cli/setup";

function withTempHome<T>(fn: (home: string) => T): T {
  const home = mkdtempSync(join(tmpdir(), "voicelayer-setup-"));
  try {
    return fn(home);
  } finally {
    rmSync(home, { recursive: true, force: true });
  }
}

describe("voicelayer setup wizard helpers", () => {
  test("detects supported agent CLIs in stable priority order", () => {
    const installed = new Set(["cursor", "claude", "gemini"]);

    expect(detectAgentClis((name) => installed.has(name))).toEqual([
      { id: "claude", command: "claude" },
      { id: "cursor", command: "cursor" },
      { id: "gemini", command: "gemini" },
    ]);
  });

  test("remembers the selected agent under ~/.voicelayer", () =>
    withTempHome((home) => {
      expect(loadRememberedAgent(home)).toBeNull();

      rememberAgent("codex", home);

      expect(loadRememberedAgent(home)).toBe("codex");
      expect(existsSync(join(home, ".voicelayer", "setup.json"))).toBe(true);
    }));

  test.each([
    ["claude", [".claude", ".mcp.json"]],
    ["cursor", [".cursor", "mcp.json"]],
    ["gemini", [".gemini", "config", "mcp_config.json"]],
  ] as const)(
    "writes idempotent JSON MCP config for %s",
    (agent: AgentId, pathParts: readonly string[]) =>
      withTempHome((home) => {
        const configPath = join(home, ...pathParts);
        mkdirSync(dirname(configPath), { recursive: true });
        writeFileSync(
          configPath,
          JSON.stringify({ mcpServers: { existing: { command: "noop" } } }),
          { flush: true },
        );

        const first = wireAgentMcpConfig(agent, home);
        const second = wireAgentMcpConfig(agent, home);
        const data = JSON.parse(readFileSync(configPath, "utf8"));

        expect(first.changed).toBe(true);
        expect(second.changed).toBe(false);
        expect(data.mcpServers.existing).toEqual({ command: "noop" });
        expect(data.mcpServers.voicelayer).toEqual({
          command: "socat",
          args: ["STDIO", "UNIX-CONNECT:/tmp/voicelayer-mcp.sock"],
        });
        expect(
          Object.keys(data.mcpServers).filter((key) => key === "voicelayer"),
        ).toHaveLength(1);
      }),
  );

  test("updates Codex TOML MCP config without duplicating the server block", () =>
    withTempHome((home) => {
      const configPath = resolveAgentConfigPath("codex", home);
      mkdirSync(dirname(configPath), { recursive: true });
      writeFileSync(
        configPath,
        [
          'model = "gpt-5"',
          "",
          "[mcp_servers.voicelayer]",
          'command = "voicelayer-mcp"',
          "startup_timeout_sec = 20",
          "",
          "[mcp_servers.voicelayer.env]",
          'OLD_ENV = "stale"',
          "",
          "[mcp_servers.brainlayer]",
          'command = "socat"',
          'args = ["STDIO", "UNIX-CONNECT:/tmp/mcplayer-brainlayer.sock"]',
          "",
        ].join("\n"),
        { flush: true },
      );

      const first = wireAgentMcpConfig("codex", home);
      const second = wireAgentMcpConfig("codex", home);
      const body = readFileSync(configPath, "utf8");

      expect(first.changed).toBe(true);
      expect(second.changed).toBe(false);
      expect(body).toContain("[mcp_servers.brainlayer]");
      expect(body).toContain("[mcp_servers.voicelayer]");
      expect(body).toContain('command = "socat"');
      expect(body).toContain(
        'args = ["STDIO", "UNIX-CONNECT:/tmp/voicelayer-mcp.sock"]',
      );
      expect(body.match(/\[mcp_servers\.voicelayer\]/g)?.length).toBe(1);
      expect(body).not.toContain("[mcp_servers.voicelayer.env]");
      expect(body).not.toContain("OLD_ENV");
      expect(body).not.toContain('command = "voicelayer-mcp"');
    }));

  test("chains build-app before hotkey install through the CLI wrapper", () => {
    expect(getSetupCommandPlan("/pkg")).toEqual([
      ["bash", "/pkg/src/cli/voicelayer.sh", "build-app"],
      ["bash", "/pkg/src/cli/voicelayer.sh", "hotkey", "install"],
    ]);
  });

  test("prints macOS TCC grant links in the required order", () => {
    expect(getTccGrantSteps().map((step) => step.name)).toEqual([
      "Microphone",
      "Accessibility",
      "Input Monitoring",
    ]);
    expect(getTccGrantSteps().map((step) => step.url)).toEqual([
      "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
      "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
      "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent",
    ]);
  });
});
