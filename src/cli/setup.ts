#!/usr/bin/env bun
import { constants, accessSync, existsSync, lstatSync, mkdirSync, readFileSync, realpathSync, rmdirSync, writeFileSync } from "fs";
import { dirname, isAbsolute, join, relative, resolve } from "path";
import { fileURLToPath } from "url";

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

export interface SetupCommandPlanOptions {
  availabilityOnly?: boolean;
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

const VOICEBAR_APP_PATH = "/Applications/VoiceBar.app";

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

function stableExecutable(candidates: (string | null)[]): string | undefined {
  return candidates.find((candidate): candidate is string => {
    if (!candidate || resolve(candidate).includes("/Cellar/")) return false;
    try { accessSync(candidate, constants.X_OK); return true; } catch { return false; }
  });
}

function voiceLayerMcpServer(home: string) {
  const command = stableExecutable([
    "/opt/homebrew/bin/bun", join(home, ".bun/bin/bun"), Bun.which("bun"),
  ]);
  const moduleBridge = fileURLToPath(new URL("../mcp-bridge.ts", import.meta.url))
    .replace(/^(.*)\/Cellar\/([^/]+)\/[^/]+\//u, "$1/opt/$2/");
  const bridge = stableExecutable([
    Bun.which("voicelayer-mcp-bridge"), "/opt/homebrew/bin/voicelayer-mcp-bridge",
    join(home, ".bun/bin/voicelayer-mcp-bridge"), moduleBridge,
  ]);
  if (!command || !bridge) throw new Error("Stable Bun and MCP bridge paths are required for setup");
  return { command: resolve(command), args: [resolve(bridge)] };
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
): WireResult {
  const path = resolveAgentConfigPath(agent, home);
  const data = readJsonConfig(path);
  const servers =
    typeof data.mcpServers === "object" && data.mcpServers !== null
      ? (data.mcpServers as Record<string, unknown>)
      : {};
  const nextServers = {
    ...servers,
    voicelayer: voiceLayerMcpServer(home),
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

function canonicalCodexBlock(home: string): string {
  const server = voiceLayerMcpServer(home);
  return [
    "[mcp_servers.voicelayer]",
    `command = ${JSON.stringify(server.command)}`,
    `args = ${JSON.stringify(server.args)}`,
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

function wireCodexMcpConfig(home: string): WireResult {
  const path = resolveAgentConfigPath("codex", home);
  const current = existsSync(path) ? readFileSync(path, "utf8") : "";
  const withoutVoiceLayer = stripTomlTable(current, "mcp_servers.voicelayer");
  const prefix = withoutVoiceLayer ? `${withoutVoiceLayer}\n\n` : "";
  const next = `${prefix}${canonicalCodexBlock(home)}`;
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
): WireResult {
  ensureUserStateDirs(home);
  if (agent === "codex") {
    return wireCodexMcpConfig(home);
  }
  return wireJsonMcpConfig(agent, home);
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
    commands.push(["bash", cli, "autostart", "install", ...(options.availabilityOnly ? ["--restore-availability"] : [])]);
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
    env: process.env,
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

function assertSetupAppPath(): void {
  if (process.env.VOICELAYER_TEST_ISOLATED !== "1") return;
  const root = process.env.VOICELAYER_TEST_RUN_ROOT;
  if (!root) throw Error("UNKNOWN: setup requires isolated root");
  const tail = relative(resolve(root), VOICEBAR_APP_PATH);
  if (!tail || tail.startsWith("..") || isAbsolute(tail)) throw Error("UNKNOWN: setup app escaped isolated root");
  const resolvedTail = relative(realpathSync(root), realpathSync(VOICEBAR_APP_PATH));
  if (!resolvedTail || resolvedTail.startsWith("..") || isAbsolute(resolvedTail)) throw Error("UNKNOWN: setup app symlink escaped isolated root");
}

function voiceBarStopped(): boolean {
  const result = Bun.spawnSync(["pgrep", "-x", "VoiceBar"], { env: process.env, stdout: "pipe", stderr: "pipe" });
  if (result.exitCode === 1) return true;
  if (result.exitCode === 0 && result.stdout.toString().trim()) return false;
  throw Error("UNKNOWN: VoiceBar process inventory unavailable");
}

async function runLegacyCaskSetup(packageRoot: string): Promise<boolean> {
  assertSetupAppPath();
  const { assertGatePath } = await import("../update-gate-installer");
  assertGatePath();
  const { updateGateFilePath } = await import("../paths");
  const gate = updateGateFilePath();
  try { lstatSync(gate); return false; }
  catch (error) { if (!(error instanceof Error) || !("code" in error) || error.code !== "ENOENT") throw error; }
  if (!existsSync(VOICEBAR_APP_PATH) || !voiceBarStopped()) throw Error("UNKNOWN: legacy setup requires an installed, stopped VoiceBar");
  for (const suffix of [".bootstrap", ".lock"]) {
    try { lstatSync(gate + suffix); throw Error("UNKNOWN: gate recovery evidence retained"); }
    catch (error) { if (!(error instanceof Error) || !("code" in error) || error.code !== "ENOENT") throw error; }
  }
  const mutex = gate + ".bootstrap-lock";
  mkdirSync(dirname(mutex), { recursive: true, mode: 0o700 });
  mkdirSync(mutex, { mode: 0o700 }); // Shared with supervised bootstrap; never reap.
  try {
    if (!voiceBarStopped()) throw Error("UNKNOWN: VoiceBar started during legacy initialization");
    const { initializeSupervisedVoiceGate } = await import("../update-gate-admission");
    // Same exclusive, crash-safe G1 initialization as supervised bootstrap. It
    // refuses every existing ledger/controller/diagnostic and never reaps a lock.
    if (!initializeSupervisedVoiceGate()) throw Error("UNKNOWN: legacy gate initialization refused");
    if (!voiceBarStopped()) throw Error("UNKNOWN: VoiceBar started during legacy initialization");
    const { readInstallerGateState } = await import("../update-gate-storage");
    if (readInstallerGateState().kind !== "OPEN") throw Error("UNKNOWN: legacy gate unavailable");
    // Cask replacement is finished: startup repair cannot build, quit or replace
    // anything. Ordinary setup on an existing gate still uses runGatedInstall.
    await runSetup(packageRoot, { getCommandPlan: root => getSetupCommandPlan(root, {
      availabilityOnly: true, appBundleExists: () => true,
    }) });
    for (let n = 0; n < 50 && voiceBarStopped(); n++) await Bun.sleep(100);
    if (voiceBarStopped()) throw Error("UNKNOWN: VoiceBar did not start after legacy setup");
    return true;
  } finally { rmdirSync(mutex); } // Only this invocation's empty supervisor lock.
}

async function restoreSetupAvailability(packageRoot: string): Promise<void> {
  assertSetupAppPath();
  // Availability recovery never quits/replaces a bundle or reopens gate evidence.
  // The plist names /Applications, so brew rollback retains the same launch path.
  voiceBarStopped(); // Unreadable inventory refuses before any repair command.
  if (!existsSync(VOICEBAR_APP_PATH)) return;
  const failures: unknown[] = [];
  for (const command of [
    ["bash", join(packageRoot, "scripts/install-voicebar-autostart.sh"), "--restore-availability"],
    ["bash", join(packageRoot, "scripts/install-voicebar-f5-hidutil.sh")],
  ]) {
    try { await runCommand(command); } catch (error) { failures.push(error); }
  }
  // launchd starts asynchronously; observe before an open fallback can race it.
  for (let n = 0; n < 50 && voiceBarStopped(); n++) await Bun.sleep(100);
  if (voiceBarStopped()) {
    try { await runCommand(["open", VOICEBAR_APP_PATH]); } catch (error) { failures.push(error); }
    for (let n = 0; n < 50 && voiceBarStopped(); n++) await Bun.sleep(100);
    if (voiceBarStopped()) failures.push(Error("VoiceBar did not start"));
  }
  if (failures.length) throw new AggregateError(failures, "RECOVERY_REQUIRED: setup availability restoration incomplete");
}

if (import.meta.main) {
  if (process.argv.slice(2).some(arg => arg === "--help" || arg === "-h")) {
    console.log("Usage: voicelayer setup (or setup.ts PACKAGE_ROOT)"); process.exit(0);
  }
  if (process.argv.length > 3) { console.error("ERROR: setup accepts no options"); process.exit(2); }
  const packageRoot = process.argv[2];
  if (!packageRoot || packageRoot.startsWith("-")) {
    console.error("Usage: setup.ts PACKAGE_ROOT");
    process.exit(2);
  }
  const { runGatedInstall, validateInstallerOperation } = await import("../update-gate-installer");
  const nested = !!process.env.VOICELAYER_INSTALL_OPERATION;
  try {
    if (!nested && await runLegacyCaskSetup(packageRoot)) {
      // Startup-only legacy setup completed; the gate remains OPEN.
    } else if (!nested) {
      process.exitCode = await runGatedInstall([process.execPath, import.meta.path, ...process.argv.slice(2)]);
    } else {
      await validateInstallerOperation();
      await runSetup(packageRoot);
    }
  } catch (error: unknown) {
    console.error(
      `[voicelayer] setup failed: ${
        error instanceof Error ? error.message : String(error)
      }`,
    );
    process.exitCode = 1;
  }
  if (process.exitCode) {
    try { await restoreSetupAvailability(packageRoot); }
    catch (error) { console.error(String(error)); process.exitCode = 1; }
  }
}
