import { describe, expect, test } from "bun:test";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "fs";
import { tmpdir } from "os";
import { testTmp } from "./setup/test-tmp";
import { dirname, join } from "path";
import { fileURLToPath } from "url";

import {
  detectAgentClis,
  getSetupCommandPlan,
  getTccGrantSteps,
  loadRememberedAgent,
  rememberAgent,
  resolveAgentConfigPath,
  runSetup,
  wireAgentMcpConfig,
  type AgentId,
} from "../cli/setup";

const bridgeScript = Bun.which("voicelayer-mcp-bridge") ?? fileURLToPath(new URL("../mcp-bridge.ts", import.meta.url));
const stableBun = ["/opt/homebrew/bin/bun", Bun.which("bun")]
  .find(path => path && !path.includes("/Cellar/") && existsSync(path));

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
          command: stableBun,
          args: [bridgeScript],
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
      expect(body).toContain(`command = ${JSON.stringify(stableBun)}`);
      expect(body).toContain(
        `args = [${JSON.stringify(bridgeScript)}]`,
      );
      expect(body.match(/\[mcp_servers\.voicelayer\]/g)?.length).toBe(1);
      expect(body).not.toContain("[mcp_servers.voicelayer.env]");
      expect(body).not.toContain("OLD_ENV");
      expect(body).not.toContain('command = "voicelayer-mcp"');
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

test("setup argv survives Homebrew VoiceLayer and Bun keg replacement", async () => {
  const root = testTmp("setup-keg-" + Math.random().toString(16).slice(2));
  mkdirSync(root, { recursive: true });
  try {
    const prefix = `${root}/homebrew`; const bin = `${prefix}/bin`; const opt = `${prefix}/opt`;
    mkdirSync(bin, { recursive: true }); mkdirSync(opt);
    for (const version of ["1", "2"]) {
      const src = `${prefix}/Cellar/voicelayer/${version}/src`;
      mkdirSync(`${src}/cli`, { recursive: true });
      writeFileSync(`${src}/cli/setup.ts`, readFileSync(new URL("../cli/setup.ts", import.meta.url), "utf8").replaceAll("/opt/homebrew/bin", bin));
      writeFileSync(`${src}/mcp-bridge.ts`, `console.log("bridge-${version}");`, { mode: 0o755 });
      mkdirSync(`${prefix}/Cellar/bun/${version}`, { recursive: true });
      symlinkSync(process.execPath, `${prefix}/Cellar/bun/${version}/bun`);
    }
    for (const pkg of ["voicelayer", "bun"]) symlinkSync(`${prefix}/Cellar/${pkg}/1`, `${opt}/${pkg}`);
    symlinkSync(`${opt}/voicelayer/src/mcp-bridge.ts`, `${bin}/voicelayer-mcp-bridge`);
    symlinkSync(`${opt}/bun/bun`, `${bin}/bun`);
    const runner = `${root}/wire.ts`;
    writeFileSync(runner, `import { wireAgentMcpConfig } from ${JSON.stringify(`${opt}/voicelayer/src/cli/setup.ts`)}; for (const agent of ["claude", "cursor", "gemini", "codex"]) wireAgentMcpConfig(agent, ${JSON.stringify(root)});`);
    const child = Bun.spawn([`${bin}/bun`, runner], { env: { ...process.env, HOME: root, PATH: bin }, stdout: "pipe", stderr: "pipe" });
    const stderr = await new Response(child.stderr).text(); expect(stderr).toBe(""); expect(await child.exited).toBe(0);
    const servers = (["claude", "cursor", "gemini", "codex"] as const).map(agent => {
      const body = readFileSync(resolveAgentConfigPath(agent, root), "utf8");
      expect(body).not.toContain("/Cellar/");
      return agent === "codex" ? Bun.TOML.parse(body).mcp_servers.voicelayer : JSON.parse(body).mcpServers.voicelayer;
    });
    for (const pkg of ["voicelayer", "bun"]) {
      rmSync(`${opt}/${pkg}`); symlinkSync(`${prefix}/Cellar/${pkg}/2`, `${opt}/${pkg}`);
      rmSync(`${prefix}/Cellar/${pkg}/1`, { recursive: true });
    }
    for (const server of servers) {
      const launched = Bun.spawn([server.command, ...server.args], { env: process.env, stdout: "pipe", stderr: "pipe" });
      expect(await launched.exited).toBe(0); expect(await new Response(launched.stdout).text()).toBe("bridge-2\n");
    }
  } finally { rmSync(root, { recursive: true, force: true }); }
});
