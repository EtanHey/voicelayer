#!/usr/bin/env bun
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "fs";
import { dirname, join } from "path";

export type AgentId = "claude" | "codex" | "cursor" | "gemini";

export interface AgentCli {
  id: AgentId;
  command: string;
}

export interface WireResult {
  agent: AgentId;
  path: string;
  changed: boolean;
}

export interface TccGrantStep {
  name: string;
  url: string;
}

export interface SocatOptions {
  socatExists?: (path: string) => boolean;
}

export interface SetupCommandPlanOptions {
  appBundlePath?: string;
  appBundleExists?: (path: string) => boolean;
  autostartInstallerExists?: (path: string) => boolean;
}

export interface SetupRunOptions {
  home?: string;
  detectAgentClis?: () => AgentCli[];
  getCommandPlan?: (packageRoot: string) => string[][];
  runCommand?: (command: string[]) => Promise<void>;
  log?: (message?: string) => void;
  warn?: (message: string) => void;
}

const AGENT_ORDER: readonly AgentCli[] = [
  { id: "claude", command: "claude" },
  { id: "codex", command: "codex" },
  { id: "cursor", command: "cursor" },
  { id: "gemini", command: "gemini" },
];

// Prefer an absolute socat so the MCP client resolves under launchd/agent
// environments with a thin PATH; fall back to bare `socat` (PATH lookup).
const SOCAT_CANDIDATES = [
  "/opt/homebrew/bin/socat", // Apple Silicon Homebrew
  "/usr/local/bin/socat", // Intel Homebrew
] as const;
const VOICEBAR_APP_PATH = "/Applications/VoiceBar.app";
const MCP_ARGS = ["STDIO", "UNIX-CONNECT:/tmp/voicelayer-mcp.sock"] as const;

function defaultHome(): string {
  const home = process.env.HOME;
  if (!home) {
    throw new Error("HOME is required");
  }
  return home;
}

function commandExists(command: string): boolean {
  return (
    Bun.spawnSync(["which", command], {
      stdout: "ignore",
      stderr: "ignore",
    }).exitCode === 0
  );
}

export function detectAgentClis(
  exists: (command: string) => boolean = commandExists,
): AgentCli[] {
  return AGENT_ORDER.filter((agent) => exists(agent.command));
}

export function resolveSocatCommand(
  exists: (path: string) => boolean = existsSync,
): string {
  return SOCAT_CANDIDATES.find(exists) ?? "socat";
}

function voiceLayerMcpServer(options: SocatOptions = {}) {
  return {
    command: resolveSocatCommand(options.socatExists),
    args: MCP_ARGS,
  };
}

export function resolveAgentConfigPath(
  agent: AgentId,
  home = defaultHome(),
): string {
  switch (agent) {
    case "claude":
      return join(home, ".claude", ".mcp.json");
    case "codex":
      return join(home, ".codex", "config.toml");
    case "cursor":
      return join(home, ".cursor", "mcp.json");
    case "gemini":
      return join(home, ".gemini", "config", "mcp_config.json");
  }
}

function setupStatePath(home = defaultHome()): string {
  return join(home, ".voicelayer", "setup.json");
}

function ensureUserStateDirs(home = defaultHome()): void {
  mkdirSync(join(home, ".voicelayer"), { recursive: true });
  mkdirSync(join(home, ".local", "state", "voicelayer"), { recursive: true });
}

export function loadRememberedAgent(home = defaultHome()): AgentId | null {
  const path = setupStatePath(home);
  if (!existsSync(path)) {
    return null;
  }
  try {
    const data = JSON.parse(readFileSync(path, "utf8")) as { agent?: unknown };
    if (
      data.agent === "claude" ||
      data.agent === "codex" ||
      data.agent === "cursor" ||
      data.agent === "gemini"
    ) {
      return data.agent;
    }
  } catch {
    return null;
  }
  return null;
}

export function rememberAgent(agent: AgentId, home = defaultHome()): void {
  ensureUserStateDirs(home);
  writeFileSync(
    setupStatePath(home),
    `${JSON.stringify({ agent, updated_at: new Date().toISOString() }, null, 2)}\n`,
  );
}

function readJsonConfig(path: string): Record<string, unknown> {
  if (!existsSync(path)) {
    return {};
  }
  const body = readFileSync(path, "utf8").trim();
  if (!body) {
    return {};
  }
  return JSON.parse(body) as Record<string, unknown>;
}

function sameJson(left: unknown, right: unknown): boolean {
  return JSON.stringify(left) === JSON.stringify(right);
}

function wireJsonMcpConfig(
  agent: AgentId,
  home: string,
  options: SocatOptions,
): WireResult {
  const path = resolveAgentConfigPath(agent, home);
  const data = readJsonConfig(path);
  const servers =
    typeof data.mcpServers === "object" && data.mcpServers !== null
      ? (data.mcpServers as Record<string, unknown>)
      : {};
  const nextServers = {
    ...servers,
    voicelayer: voiceLayerMcpServer(options),
  };
  const nextData = {
    ...data,
    mcpServers: nextServers,
  };
  const changed = !sameJson(data, nextData);

  if (changed) {
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, `${JSON.stringify(nextData, null, 2)}\n`);
  }

  return { agent, path, changed };
}

function canonicalCodexBlock(options: SocatOptions = {}): string {
  return [
    "[mcp_servers.voicelayer]",
    `command = "${resolveSocatCommand(options.socatExists)}"`,
    'args = ["STDIO", "UNIX-CONNECT:/tmp/voicelayer-mcp.sock"]',
    "startup_timeout_sec = 20",
    "",
  ].join("\n");
}

function stripTomlTable(body: string, tableName: string): string {
  const lines = body.split("\n");
  const kept: string[] = [];
  let skipping = false;

  for (const line of lines) {
    const trimmed = line.trim();
    const tableMatch = trimmed.match(/^\[([^\]]+)\]$/u);
    if (tableMatch) {
      const currentTable = tableMatch[1] ?? "";
      if (
        currentTable === tableName ||
        currentTable.startsWith(`${tableName}.`)
      ) {
        skipping = true;
        continue;
      }
      skipping = false;
    }
    if (!skipping) {
      kept.push(line);
    }
  }

  return kept.join("\n").replace(/\s+$/u, "");
}

function wireCodexMcpConfig(home: string, options: SocatOptions): WireResult {
  const path = resolveAgentConfigPath("codex", home);
  const current = existsSync(path) ? readFileSync(path, "utf8") : "";
  const withoutVoiceLayer = stripTomlTable(current, "mcp_servers.voicelayer");
  const prefix = withoutVoiceLayer ? `${withoutVoiceLayer}\n\n` : "";
  const next = `${prefix}${canonicalCodexBlock(options)}`;
  const changed = current !== next;

  if (changed) {
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, next);
  }

  return { agent: "codex", path, changed };
}

export function wireAgentMcpConfig(
  agent: AgentId,
  home = defaultHome(),
  options: SocatOptions = {},
): WireResult {
  ensureUserStateDirs(home);
  if (agent === "codex") {
    return wireCodexMcpConfig(home, options);
  }
  return wireJsonMcpConfig(agent, home, options);
}

export function getSetupCommandPlan(
  packageRoot: string,
  options: SetupCommandPlanOptions = {},
): string[][] {
  const cli = join(packageRoot, "src", "cli", "voicelayer.sh");
  const appBundlePath = options.appBundlePath ?? VOICEBAR_APP_PATH;
  const appBundleExists = options.appBundleExists ?? existsSync;
  const autostartInstallerExists =
    options.autostartInstallerExists ?? existsSync;
  const commands: string[][] = [];

  if (!appBundleExists(appBundlePath)) {
    commands.push(["bash", cli, "build-app"]);
  }
  if (
    autostartInstallerExists(
      join(packageRoot, "scripts", "install-voicebar-autostart.sh"),
    )
  ) {
    commands.push(["bash", cli, "autostart", "install"]);
  }
  commands.push(["bash", cli, "hotkey", "install"]);
  return commands;
}

export function getTccGrantSteps(): TccGrantStep[] {
  return [
    {
      name: "Microphone",
      url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
    },
    {
      name: "Accessibility",
      url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
    },
    {
      name: "Input Monitoring",
      url: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent",
    },
  ];
}

function chooseAgent(detected: readonly AgentCli[], home: string): AgentId {
  const remembered = loadRememberedAgent(home);
  if (remembered && detected.some((agent) => agent.id === remembered)) {
    return remembered;
  }
  if (detected.length === 1) {
    return detected[0]?.id ?? "claude";
  }

  console.log("Detected agent CLIs:");
  detected.forEach((agent, index) => {
    const defaultMark = index === 0 ? " (default)" : "";
    console.log(`  ${index + 1}. ${agent.id}${defaultMark}`);
  });
  const answer = process.stdin.isTTY
    ? (globalThis.prompt?.("Choose agent to wire [1]: ")?.trim() ?? "")
    : "";
  if (!answer) {
    return detected[0]?.id ?? "claude";
  }
  const selectedIndex = Number.parseInt(answer, 10) - 1;
  const selected = detected[selectedIndex];
  if (!selected) {
    throw new Error(`Invalid agent selection: ${answer}`);
  }
  return selected.id;
}

async function runCommand(command: string[]): Promise<void> {
  const proc = Bun.spawn(command, {
    stdout: "inherit",
    stderr: "inherit",
  });
  const exitCode = await proc.exited;
  if (exitCode !== 0) {
    throw new Error(`Command failed (${exitCode}): ${command.join(" ")}`);
  }
}

export async function runSetup(
  packageRoot: string,
  options: SetupRunOptions = {},
): Promise<void> {
  const home = options.home ?? defaultHome();
  const log = options.log ?? console.log;
  const warn = options.warn ?? console.warn;
  const runSetupCommand = options.runCommand ?? runCommand;
  const commandPlan = options.getCommandPlan ?? getSetupCommandPlan;

  ensureUserStateDirs(home);
  const detected = options.detectAgentClis
    ? options.detectAgentClis()
    : detectAgentClis();
  if (detected.length === 0) {
    warn(
      "[voicelayer] No supported agent CLI found in PATH; skipping MCP config wiring.",
    );
  } else {
    const agent = chooseAgent(detected, home);
    rememberAgent(agent, home);
    const wired = wireAgentMcpConfig(agent, home);
    log(
      `[voicelayer] Wired ${agent} MCP config: ${wired.path} (${wired.changed ? "updated" : "already current"})`,
    );
  }

  for (const command of commandPlan(packageRoot)) {
    await runSetupCommand(command);
  }

  log("");
  log("Grant macOS permissions in this order:");
  getTccGrantSteps().forEach((step, index) => {
    log(`  ${index + 1}. ${step.name}: ${step.url}`);
  });
}

if (import.meta.main) {
  const packageRoot = process.argv[2];
  if (!packageRoot) {
    console.error("Usage: setup.ts PACKAGE_ROOT");
    process.exit(2);
  }
  runSetup(packageRoot).catch((error: unknown) => {
    console.error(
      `[voicelayer] setup failed: ${
        error instanceof Error ? error.message : String(error)
      }`,
    );
    process.exit(1);
  });
}
