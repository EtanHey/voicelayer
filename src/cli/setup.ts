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

function assertSetupHost(): void {
  if (process.env.VOICELAYER_TEST_ISOLATED !== "1") return;
  const root = process.env.VOICELAYER_TEST_RUN_ROOT;
  if (!root) throw Error("UNKNOWN: setup requires isolated root");
  const check = (path: string, name: string) => {
    const tail = relative(realpathSync(root), resolve(path));
    if (!tail || tail.startsWith("..") || isAbsolute(tail)) throw Error(`UNKNOWN: setup ${name} escaped isolated root`);
    const physical = relative(realpathSync(root), realpathSync(path));
    if (!physical || physical.startsWith("..") || isAbsolute(physical)) throw Error(`UNKNOWN: setup ${name} symlink escaped isolated root`);
  };
  check(defaultHome(), "HOME");
  check(Bun.which("launchctl") ?? "", "launchctl");
  check(VOICEBAR_APP_PATH, "app");
}

function voiceBarStopped(): boolean {
  const result = Bun.spawnSync(["pgrep", "-x", "VoiceBar"], { env: process.env, stdout: "pipe", stderr: "pipe" });
  if (result.exitCode === 1) return true;
  if (result.exitCode === 0 && result.stdout.toString().trim()) return false;
  throw Error("UNKNOWN: VoiceBar process inventory unavailable");
}
function canonicalVoiceBarRunning(): boolean {
  const result = Bun.spawnSync(["pgrep", "-x", "VoiceBar"], { env: process.env, stdout: "pipe", stderr: "pipe" });
  if (result.exitCode === 1) return false;
  const pid = result.stdout.toString().trim();
  if (result.exitCode !== 0 || !/^[1-9]\d*$/.test(pid)) throw Error("UNKNOWN: ambiguous VoiceBar process inventory");
  const executable = Bun.spawnSync(["ps", "-p", pid, "-o", "comm="], { env: process.env, stdout: "pipe", stderr: "pipe" });
  if (executable.exitCode !== 0 || executable.stdout.toString().trim() !== join(VOICEBAR_APP_PATH, "Contents/MacOS/VoiceBar"))
    throw Error("UNKNOWN: VoiceBar is not running from the final canonical bundle");
  return true;
}
function evidenceExists(path: string): boolean {
  try { lstatSync(path); return true; }
  catch (error) { if (error instanceof Error && "code" in error && error.code === "ENOENT") return false; throw error; }
}
const faultMessage = (error: unknown) => error instanceof Error ? error.message : String(error);
const recoveryRequired = (fault: unknown) => console.error(`[voicelayer] RECOVERY_REQUIRED: ${faultMessage(fault)}`);

async function writeSetupAgents(packageRoot: string, plistsOnly: boolean): Promise<unknown[]> {
  const failures: unknown[] = [];
  const env = { ...process.env, VOICELAYER_SETUP_AVAILABILITY: "1", VOICELAYER_SETUP_PLISTS_ONLY: plistsOnly ? "1" : "0" };
  for (const command of [
    ["bash", join(packageRoot, "scripts/install-voicebar-autostart.sh"), "--restore-availability"],
    ["bash", join(packageRoot, "scripts/install-voicebar-f5-hidutil.sh")],
  ]) {
    try {
      const status = await Bun.spawn(command, { env, stdout: "inherit", stderr: "inherit" }).exited;
      if (status !== 0) throw Error(`agent installer exited ${status}: ${command[1]}`);
    } catch (error) { failures.push(error); }
  }
  return failures;
}
async function restoreSetupAvailability(packageRoot: string): Promise<void> {
  const { hasLiveInstallerController } = await import("../update-gate-installer");
  if (hasLiveInstallerController()) throw Error("live controller owns restoration");
  const failures = await writeSetupAgents(packageRoot, false);
  // A partial first repair can leave one valid plist behind. Attempt both
  // canonical repairs once more, retaining every original error in the report.
  if (failures.length) failures.push(...await writeSetupAgents(packageRoot, false));
  for (let n = 0; n < 50 && !canonicalVoiceBarRunning(); n++) await Bun.sleep(100);
  if (!canonicalVoiceBarRunning()) {
    const job = Bun.spawnSync(["launchctl", "print", `gui/${process.getuid!()}/com.voicelayer.voicebar`], { env: process.env, stdout: "pipe", stderr: "pipe" });
    // A loaded job that is starting/running owns the launch. Only a job which
    // never started (or is absent) permits the LaunchServices fallback.
    if (job.exitCode !== 0 || /state = (not running|exited)/.test(job.stdout.toString())) {
      if (hasLiveInstallerController()) throw Error("live controller owns restoration");
      try { await runCommand(["open", VOICEBAR_APP_PATH]); } catch (error) { failures.push(error); }
      for (let n = 0; n < 50 && !canonicalVoiceBarRunning(); n++) await Bun.sleep(100);
    }
  }
  for (const error of failures) recoveryRequired(error);
  if (!canonicalVoiceBarRunning()) throw Error("VoiceBar could not be made to run from the final canonical bundle; plists retained");
}

async function runCaskPostflight(packageRoot: string): Promise<"controller" | "restored"> {
  assertSetupHost(); // Before even reading a gate or invoking an installer.
  const { assertGatePath, hasLiveInstallerController, validateInstallerOperation } = await import("../update-gate-installer");
  assertGatePath();
  const { updateGateFilePath } = await import("../paths");
  const { readUpdateGateFile } = await import("../update-gate-storage");
  const gate = updateGateFilePath(), mutex = gate + ".bootstrap-lock";
  let ownsMutex = false;
  const cancel = (signal: string) => recoveryRequired(`${signal}: completing availability restoration before return`);
  const signals = ["SIGINT", "SIGTERM", "SIGHUP", "SIGQUIT"] as const;
  const handlers = signals.map(signal => {
    const handler = () => cancel(signal);
    process.on(signal, handler);
    return [signal, handler] as const;
  });
  const faults: unknown[] = [];
  try {
    const operation = process.env.HOMEBREW_VOICELAYER_INSTALL_OPERATION;
    if (operation) {
      // Never adopt an unvalidated HOMEBREW_* value as a nested capability.
      process.env.VOICELAYER_INSTALL_OPERATION = operation;
      try {
        await validateInstallerOperation();
        const failures = await writeSetupAgents(packageRoot, true);
        if (failures.length) throw new AggregateError(failures, "plist-only setup incomplete");
        return "controller";
      } catch (error) { faults.push(error); }
      finally { delete process.env.VOICELAYER_INSTALL_OPERATION; }
    }
    // A live persisted identity fences startup even when validation/state is faulty.
    if (hasLiveInstallerController()) {
      const state = readUpdateGateFile();
      if (state.kind === "OPEN" || state.kind === "UNKNOWN") faults.push(Error(`gate ${state.kind} with live controller`));
      const failures = await writeSetupAgents(packageRoot, true);
      for (const fault of [...faults, ...failures]) recoveryRequired(fault);
      return "controller";
    }
    try {
      if (faults.length) throw Error("UNKNOWN: inherited operation validation failed; gate evidence retained");
      if (!evidenceExists(gate)) {
        if (!existsSync(VOICEBAR_APP_PATH) || !voiceBarStopped()) throw Error("UNKNOWN: legacy setup requires an installed, stopped VoiceBar");
        for (const suffix of [".bootstrap", ".lock"]) if (evidenceExists(gate + suffix)) throw Error(`UNKNOWN: gate recovery evidence retained: ${suffix}`);
        mkdirSync(dirname(mutex), { recursive: true, mode: 0o700 });
        try { mkdirSync(mutex, { mode: 0o700 }); }
        catch { throw Error("UNKNOWN: another bootstrap or recovery owns this host (.bootstrap-lock retained)"); }
        ownsMutex = true;
        if (!voiceBarStopped()) throw Error("UNKNOWN: VoiceBar started during legacy initialization");
        const { initializeSupervisedVoiceGate } = await import("../update-gate-admission");
        if (!initializeSupervisedVoiceGate()) throw Error("UNKNOWN: legacy gate initialization refused; evidence retained");
        if (!voiceBarStopped()) throw Error("UNKNOWN: VoiceBar started during legacy initialization");
      }
      const state = readUpdateGateFile();
      if (state.kind !== "OPEN") throw Error(`UNKNOWN: gate ${state.kind} without a live controller`);
      for (const suffix of [".bootstrap", ".controller", ".voice-diag.json"])
        if (evidenceExists(gate + suffix)) throw Error(`UNKNOWN: gate recovery evidence retained: ${suffix}`);
      if (!ownsMutex && evidenceExists(mutex)) throw Error("UNKNOWN: another bootstrap or recovery owns this host (.bootstrap-lock retained)");
    } catch (error) { faults.push(error); }
    for (const fault of faults) recoveryRequired(fault);
    await restoreSetupAvailability(packageRoot);
    return "restored";
  } finally {
    if (ownsMutex) {
      try { rmdirSync(mutex); }
      catch (error) { recoveryRequired(`bootstrap mutex cleanup failed separately: ${faultMessage(error)}`); }
    }
    for (const [signal, handler] of handlers) process.off(signal, handler);
  }
}

if (import.meta.main) {
  const args = process.argv.slice(2), packageRoot = args[0];
  if (args.some(arg => arg === "--help" || arg === "-h")) {
    console.log("Usage: voicelayer setup [--cask-postflight] (or setup.ts PACKAGE_ROOT [--cask-postflight])"); process.exit(0);
  }
  if (!packageRoot || packageRoot.startsWith("-") || args.length > 2 || (args[1] && args[1] !== "--cask-postflight")) {
    console.error("ERROR: setup accepts only PACKAGE_ROOT [--cask-postflight]"); process.exit(2);
  }
  try {
    assertSetupHost();
    const { runGatedInstall, validateInstallerOperation } = await import("../update-gate-installer");
    if (process.env.VOICELAYER_INSTALL_OPERATION) {
      // Manual nested helpers never restore: the owning shell re-exec does it.
      await validateInstallerOperation();
      const failures = await writeSetupAgents(packageRoot, true);
      if (failures.length) throw new AggregateError(failures, "nested plist setup incomplete");
      await runSetup(packageRoot, { getCommandPlan: () => [] });
    } else if (args[1] === "--cask-postflight" || existsSync(VOICEBAR_APP_PATH)) {
      // Current casks pass no flag: an installed canonical bundle keeps that
      // invocation on the same availability-only path. No update lease here.
      const outcome = await runCaskPostflight(packageRoot);
      if (outcome === "restored" && !args[1]) {
        // Preserve no-flag setup's MCP wiring and permission guidance. A wiring
        // fault must not make brew delete the verified running bundle.
        try { await runSetup(packageRoot, { getCommandPlan: () => [] }); }
        catch (error) { recoveryRequired(error); }
      }
    } else {
      process.exitCode = await runGatedInstall([process.execPath, import.meta.path, ...args]);
    }
  } catch (error) {
    recoveryRequired(error);
    process.exitCode = 1;
  }
}
