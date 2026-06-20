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
  resolveSocatCommand,
  resolveAgentConfigPath,
  runSetup,
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

        const options = { socatExists: () => false };
        const first = wireAgentMcpConfig(agent, home, options);
        const second = wireAgentMcpConfig(agent, home, options);
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

      const options = { socatExists: () => false };
      const first = wireAgentMcpConfig("codex", home, options);
      const second = wireAgentMcpConfig("codex", home, options);
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

  test("pins Homebrew socat when it exists", () => {
    expect(
      resolveSocatCommand((path) => path === "/opt/homebrew/bin/socat"),
    ).toBe("/opt/homebrew/bin/socat");
    expect(resolveSocatCommand(() => false)).toBe("socat");
  });

  test("pins Intel Homebrew socat when only /usr/local exists", () => {
    expect(resolveSocatCommand((path) => path === "/usr/local/bin/socat")).toBe(
      "/usr/local/bin/socat",
    );
  });

  test("writes absolute socat path into MCP config when Homebrew socat exists", () =>
    withTempHome((home) => {
      const configPath = resolveAgentConfigPath("cursor", home);
      const result = wireAgentMcpConfig("cursor", home, {
        socatExists: (path) => path === "/opt/homebrew/bin/socat",
      });
      const data = JSON.parse(readFileSync(configPath, "utf8"));

      expect(result.changed).toBe(true);
      expect(data.mcpServers.voicelayer).toEqual({
        command: "/opt/homebrew/bin/socat",
        args: ["STDIO", "UNIX-CONNECT:/tmp/voicelayer-mcp.sock"],
      });
    }));

  test("writes absolute socat path into Codex TOML when Homebrew socat exists", () =>
    withTempHome((home) => {
      const configPath = resolveAgentConfigPath("codex", home);
      wireAgentMcpConfig("codex", home, {
        socatExists: (path) => path === "/opt/homebrew/bin/socat",
      });
      const body = readFileSync(configPath, "utf8");

      expect(body).toContain('command = "/opt/homebrew/bin/socat"');
      expect(body).toContain(
        'args = ["STDIO", "UNIX-CONNECT:/tmp/voicelayer-mcp.sock"]',
      );
    }));

  test("skips build-app for cask-installed VoiceBar while preserving install steps", () => {
    expect(
      getSetupCommandPlan("/pkg", {
        appBundleExists: () => true,
        autostartInstallerExists: () => true,
      }),
    ).toEqual([
      ["bash", "/pkg/src/cli/voicelayer.sh", "autostart", "install"],
      ["bash", "/pkg/src/cli/voicelayer.sh", "hotkey", "install"],
    ]);
  });

  test("includes build-app when VoiceBar is absent", () => {
    expect(
      getSetupCommandPlan("/pkg", {
        appBundleExists: () => false,
        autostartInstallerExists: () => true,
      }),
    ).toEqual([
      ["bash", "/pkg/src/cli/voicelayer.sh", "build-app"],
      ["bash", "/pkg/src/cli/voicelayer.sh", "autostart", "install"],
      ["bash", "/pkg/src/cli/voicelayer.sh", "hotkey", "install"],
    ]);
  });

  test("continues setup commands when no agent CLI is detected", async () => {
    const commands: string[][] = [];
    const warnings: string[] = [];

    await withTempHome(async (home) => {
      await runSetup("/pkg", {
        home,
        detectAgentClis: () => [],
        getCommandPlan: () => [
          ["bash", "/pkg/src/cli/voicelayer.sh", "hotkey", "install"],
        ],
        runCommand: (command) => {
          commands.push(command);
          return Promise.resolve();
        },
        log: () => {},
        warn: (message) => {
          warnings.push(message);
        },
      });
    });

    expect(commands).toEqual([
      ["bash", "/pkg/src/cli/voicelayer.sh", "hotkey", "install"],
    ]);
    expect(warnings).toEqual([
      "[voicelayer] No supported agent CLI found in PATH; skipping MCP config wiring.",
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
