/**
 * whisper-server lifecycle manager.
 *
 * Manages a whisper-server sidecar process for streaming STT.
 * The server is started lazily on first use and kept alive for the session.
 *
 * AIDEV-NOTE: whisper-server is the HTTP server from whisper.cpp.
 * It's installed via `brew install whisper-cpp` (includes whisper-server binary).
 * We POST WAV audio chunks to /inference and get back JSON transcriptions.
 */

import { homedir } from "os";
import { join } from "path";
import { existsSync } from "fs";
import { resolveBinary, resolveBinaryAsync } from "./resolve-binary";
import type { TranscriptSegment } from "./stt-sentence-boundaries";
import {
  configureWhisperPerformanceRestart,
  getWhisperPerformanceEffort,
  parseWhisperPerformanceEffort,
  whisperPerformanceArgsForEffort,
  type WhisperPerformanceEffort,
} from "./whisper-performance";
import {
  clearWhisperServerOwnership,
  portOwnerPids,
  readWhisperServerOwnership,
  writeWhisperServerOwnership,
} from "./whisper-server-ownership";

/** Default port for the whisper-server sidecar. */
const DEFAULT_PORT = 8178;

/** Health check timeout in ms. */
const HEALTH_TIMEOUT = 2000;

/** Max time to wait for server startup in ms. */
const STARTUP_TIMEOUT = 30000;

/** Max time to wait for `whisper-server --help` capability probing. */
const HELP_PROBE_TIMEOUT = 2000;

/** Max time to wait for a killed failed launch to release its port. */
const FAILED_LAUNCH_EXIT_TIMEOUT = 1000;

/** Max time to wait for the `lsof` port-ownership probe. */
const PORT_OWNER_PROBE_TIMEOUT = 1000;

/** Known whisper-server binary names. */
const SERVER_BINARY_NAMES = ["whisper-server"];

/** Model search (same order as stt.ts). */
const MODEL_SEARCH_PATHS = [
  () => join(homedir(), ".cache", "whisper", "ggml-large-v3-turbo.bin"),
  () => join(homedir(), ".cache", "whisper", "ggml-large-v3-turbo-q5_0.bin"),
  () => join(homedir(), ".cache", "whisper", "ggml-base.en.bin"),
  () => join(homedir(), ".cache", "whisper", "ggml-base.bin"),
];

interface WhisperServerState {
  /**
   * Null when the server was adopted rather than launched here. An adopted
   * server is not ours to signal: every kill path must check this first.
   */
  proc: ReturnType<typeof Bun.spawn> | null;
  port: number;
  pid: number;
  /** True when another process launched this server and we are reusing it. */
  adopted: boolean;
}

type WhisperServerProcess = ReturnType<typeof Bun.spawn>;
type WhisperServerSpawn = (
  args: string[],
  options: {
    stdout: "pipe";
    stderr: "pipe";
    env: Record<string, string>;
  },
) => Pick<WhisperServerProcess, "pid" | "kill"> & {
  exited?: Promise<number>;
  stderr?: ReadableStream<Uint8Array> | null;
  /** null/undefined while running; a number once the child has exited. */
  exitCode?: number | null;
};

export type WhisperAccelerationRequest = "auto" | "metal" | "coreml" | "cpu";
export type WhisperAccelerationMode = "metal" | "coreml" | "cpu";

export interface WhisperAccelerationPlan {
  requested: WhisperAccelerationRequest;
  mode: WhisperAccelerationMode;
  args: string[];
  env: Record<string, string>;
  warnings: string[];
}

interface ResolveAccelerationOptions {
  requested?: WhisperAccelerationRequest;
  helpText?: string;
  metalResourcesPath?: string;
  coreMLModelPath?: string;
  exists?: (path: string) => boolean;
}

interface BuildLaunchPlanOptions {
  binary: string;
  model: string;
  port: number;
  helpText?: string;
  metalResourcesPath?: string;
  coreMLModelPath?: string;
  requestedAcceleration?: WhisperAccelerationRequest;
  performanceEffort?: WhisperPerformanceEffort;
  inheritedEnv?: Record<string, string | undefined>;
  exists?: (path: string) => boolean;
}

export interface WhisperServerLaunchPlan {
  args: string[];
  env: Record<string, string>;
  acceleration: WhisperAccelerationPlan;
}

interface WhisperServerHelpProbeResult {
  helpText: string;
  warning?: string;
}

type WhisperServerHelpRunner = (
  args: string[],
  options: {
    stdout: "pipe";
    stderr: "pipe";
    timeout: number;
    killSignal: string;
  },
) => {
  stdout?: { toString(): string } | string;
  stderr?: { toString(): string } | string;
  exitCode?: number | null;
  exitedDueToTimeout?: boolean;
  error?: unknown;
};

interface CoreMLRuntimeFlag {
  flag: string;
  requiresModelPath: boolean;
}

let serverState: WhisperServerState | null = null;
const launchPromises = new Map<number, Promise<number>>();

interface WhisperServerTestHooks {
  findServerBinary?: () => string | null;
  findModel?: () => string | null;
  readHelpText?: (binary: string) => WhisperServerHelpProbeResult;
  spawn?: WhisperServerSpawn;
  isServerHealthy?: (port: number) => Promise<boolean>;
  findExternalWhisperServerPids?: (port: number) => number[];
  findPortListenerPids?: (port: number) => number[];
  killExternalPid?: (pid: number, signal: NodeJS.Signals) => void;
  isPidAlive?: (pid: number) => boolean;
  sleep?: (ms: number) => Promise<void>;
  startupTimeoutMs?: number;
}

let testHooks: WhisperServerTestHooks = {};

export function __setWhisperServerTestHooksForTests(
  hooks: WhisperServerTestHooks,
): void {
  testHooks = hooks;
}

/** Find whisper-server binary. */
function findServerBinary(): string | null {
  for (const name of SERVER_BINARY_NAMES) {
    const resolved = resolveBinary(name, [
      `/opt/homebrew/bin/${name}`,
      `/usr/local/bin/${name}`,
    ]);
    if (resolved) return resolved;
  }
  return null;
}

/**
 * The whisper-server binary this process would launch, resolved WITHOUT
 * blocking the event loop. Exported so provenance can report the version of the
 * binary actually in play instead of whatever `brew list --versions whisper-cpp`
 * happens to say is installed.
 *
 * AIDEV-NOTE: async on purpose. The sync `findServerBinary()` goes through
 * `resolveBinary`, which spawns `which` and `<candidate> --version` with
 * `Bun.spawnSync` and no timeout — a hanging binary would block daemon startup.
 * Anything on the provenance prime path must use this, never `findServerBinary`.
 */
export function resolveWhisperServerBinaryAsync(
  timeoutMs?: number,
): Promise<string | null> {
  return resolveFirstBinaryAsync(SERVER_BINARY_NAMES, timeoutMs);
}

async function resolveFirstBinaryAsync(
  names: readonly string[],
  timeoutMs?: number,
): Promise<string | null> {
  for (const name of names) {
    const resolved = await resolveBinaryAsync(
      name,
      [`/opt/homebrew/bin/${name}`, `/usr/local/bin/${name}`],
      timeoutMs,
    );
    if (resolved) return resolved;
  }
  return null;
}

/**
 * Provenance of the resident whisper-server: the model and flags it was
 * actually launched with. Recorded so every archived recording can say which
 * whisper build produced it (see src/recording-provenance.ts).
 *
 * Null when this process neither launched the resident server nor found an
 * ownership record naming its launcher — an adopted server whose launcher left
 * no record has no provenance, and reporting the flags we *would* have used
 * would be a guess.
 */
export interface WhisperServerLaunchRecord {
  binary: string;
  modelPath: string;
  args: string[];
  performanceEffort: WhisperPerformanceEffort;
  accelerationMode: WhisperAccelerationMode;
  /** PID of the resident server, so a server log line ties to a recording. */
  pid: number;
  /** ISO-8601 instant the server was observed healthy. */
  startedAt: string;
  /** True when another process launched this server and we adopted it. */
  adopted?: boolean;
  /** PID of the process that launched an adopted server. */
  ownerPid?: number;
  /**
   * False when an adopted server was launched with a model or effort tier that
   * differs from what this process would have used. Not a reason to kill it —
   * transcription still works — but the caller deserves to know.
   */
  flagsMatch?: boolean;
}

let lastLaunchRecord: WhisperServerLaunchRecord | null = null;

export function whisperServerLaunchRecord(): WhisperServerLaunchRecord | null {
  return lastLaunchRecord;
}

export function __clearWhisperServerLaunchRecordForTests(): void {
  lastLaunchRecord = null;
}

export function __setWhisperServerLaunchRecordForTests(
  record: WhisperServerLaunchRecord,
): void {
  lastLaunchRecord = record;
}

/** The model this process's configuration resolves to, or null if none found. */
export function resolveWhisperModelPath(): string | null {
  return testHooks.findModel?.() ?? findModel();
}

/** Find a whisper model file. */
function findModel(): string | null {
  const envModel = process.env.QA_VOICE_WHISPER_MODEL;
  if (envModel && existsSync(envModel)) return envModel;

  for (const pathFn of MODEL_SEARCH_PATHS) {
    const p = pathFn();
    if (existsSync(p)) return p;
  }
  return null;
}

function normalizeAccelerationRequest(
  value?: string,
): WhisperAccelerationRequest {
  const normalized = (value || "auto").trim().toLowerCase();
  if (
    normalized === "auto" ||
    normalized === "metal" ||
    normalized === "coreml" ||
    normalized === "cpu"
  ) {
    return normalized;
  }
  return "auto";
}

function getRequestedAccelerationFromEnv(): WhisperAccelerationRequest {
  const explicit = process.env.QA_VOICE_WHISPER_ACCELERATION;
  if (explicit) return normalizeAccelerationRequest(explicit);

  const coreML = (process.env.QA_VOICE_WHISPER_COREML || "")
    .trim()
    .toLowerCase();
  if (coreML === "1" || coreML === "true" || coreML === "yes") {
    return "coreml";
  }

  return "auto";
}

function findCoreMLRuntimeFlag(helpText: string): CoreMLRuntimeFlag | null {
  for (const line of helpText.split("\n")) {
    const optionTokens = line.match(/--[A-Za-z0-9][A-Za-z0-9-]*/g) ?? [];
    for (const token of optionTokens) {
      if (token === "--coreml" || token === "--core-ml") {
        return { flag: token, requiresModelPath: false };
      }
      if (token === "--coreml-model" || token === "--core-ml-model") {
        return { flag: token, requiresModelPath: true };
      }
    }
  }
  return null;
}

export function resolveWhisperAccelerationPlan(
  options: ResolveAccelerationOptions = {},
): WhisperAccelerationPlan {
  const requested = options.requested ?? "auto";
  const helpText = options.helpText ?? "";
  const exists = options.exists ?? existsSync;
  const warnings: string[] = [];

  const metalPlan = (): WhisperAccelerationPlan => {
    const env: Record<string, string> = {};
    if (options.metalResourcesPath) {
      env.GGML_METAL_PATH_RESOURCES = options.metalResourcesPath;
    }
    return { requested, mode: "metal", args: [], env, warnings };
  };

  if (requested === "cpu") {
    return { requested, mode: "cpu", args: ["--no-gpu"], env: {}, warnings };
  }

  if (requested === "coreml") {
    const coreMLPath = options.coreMLModelPath;
    const coreMLFlag = findCoreMLRuntimeFlag(helpText);

    if (!coreMLFlag) {
      warnings.push(
        "Core ML requested but this whisper-server binary exposes no Core ML runtime flag; falling back to Metal.",
      );
      return metalPlan();
    }

    if (!coreMLFlag.requiresModelPath) {
      return {
        requested,
        mode: "coreml",
        args: [coreMLFlag.flag],
        env: {},
        warnings,
      };
    }

    if (!coreMLPath) {
      warnings.push(
        "Core ML requested but QA_VOICE_WHISPER_COREML_MODEL is not set; falling back to Metal.",
      );
      return metalPlan();
    }

    if (!exists(coreMLPath)) {
      warnings.push(
        `Core ML requested but .mlpackage path does not exist: ${coreMLPath}; falling back to Metal.`,
      );
      return metalPlan();
    }

    return {
      requested,
      mode: "coreml",
      args: [coreMLFlag.flag, coreMLPath],
      env: {},
      warnings,
    };
  }

  return metalPlan();
}

export function buildWhisperServerLaunchPlan(
  options: BuildLaunchPlanOptions,
): WhisperServerLaunchPlan {
  const inheritedEnv = options.inheritedEnv ?? process.env;
  const env: Record<string, string> = {};
  for (const [k, v] of Object.entries(inheritedEnv)) {
    if (typeof v === "string") env[k] = v;
  }

  const acceleration = resolveWhisperAccelerationPlan({
    requested: options.requestedAcceleration ?? "auto",
    helpText: options.helpText,
    metalResourcesPath: options.metalResourcesPath,
    coreMLModelPath: options.coreMLModelPath,
    exists: options.exists,
  });

  Object.assign(env, acceleration.env);

  const args = [
    options.binary,
    "-m",
    options.model,
    "--port",
    String(options.port),
    "--host",
    "127.0.0.1",
    "-t",
    "4",
    ...whisperPerformanceArgsForEffort(
      options.performanceEffort ?? getWhisperPerformanceEffort(inheritedEnv),
    ),
    ...acceleration.args,
  ];

  return { args, env, acceleration };
}

export function readWhisperServerHelpText(
  binary: string,
  runner: WhisperServerHelpRunner = (args, options) =>
    Bun.spawnSync({
      cmd: args,
      stdout: options.stdout,
      stderr: options.stderr,
      timeout: options.timeout,
      killSignal: options.killSignal,
    }),
): WhisperServerHelpProbeResult {
  try {
    const result = runner([binary, "--help"], {
      stdout: "pipe",
      stderr: "pipe",
      timeout: HELP_PROBE_TIMEOUT,
      killSignal: "SIGKILL",
    });

    if (result.exitedDueToTimeout) {
      return {
        helpText: "",
        warning:
          "whisper-server --help probe timed out; falling back to Metal-safe launch defaults.",
      };
    }

    if (result.error || result.exitCode !== 0) {
      return {
        helpText: "",
        warning:
          "whisper-server --help probe failed; falling back to Metal-safe launch defaults.",
      };
    }

    return {
      helpText: `${result.stdout?.toString() ?? ""}\n${
        result.stderr?.toString() ?? ""
      }`,
    };
  } catch (err) {
    return {
      helpText: "",
      warning: `whisper-server --help probe failed: ${
        err instanceof Error ? err.message : String(err)
      }; falling back to Metal-safe launch defaults.`,
    };
  }
}

/** Check if the server is healthy. */
export async function isServerHealthy(
  port: number = DEFAULT_PORT,
): Promise<boolean> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), HEALTH_TIMEOUT);
  try {
    const resp = await fetch(`http://127.0.0.1:${port}/health`, {
      signal: controller.signal,
    });
    if (!resp.ok) return false;
    const body = await resp.json();
    return body?.status === "ok";
  } catch {
    return false;
  } finally {
    clearTimeout(timer);
  }
}

async function checkServerHealthy(port: number): Promise<boolean> {
  if (testHooks.isServerHealthy) return testHooks.isServerHealthy(port);
  return isServerHealthy(port);
}

async function sleep(ms: number): Promise<void> {
  if (testHooks.sleep) return testHooks.sleep(ms);
  return Bun.sleep(ms);
}

function getStartupTimeoutMs(): number {
  return testHooks.startupTimeoutMs ?? STARTUP_TIMEOUT;
}

type KillableWhisperServerProcess = Pick<WhisperServerProcess, "kill"> & {
  exited?: Promise<number>;
};

function killWhisperProcess(
  proc: KillableWhisperServerProcess,
  signal: NodeJS.Signals,
): void {
  try {
    proc.kill(signal);
  } catch {}
}

async function waitForWhisperProcessExit(
  proc: KillableWhisperServerProcess,
): Promise<boolean> {
  if (!proc.exited) return true;

  const result = await Promise.race([
    proc.exited.then(
      () => "exited" as const,
      () => "exited" as const,
    ),
    Bun.sleep(FAILED_LAUNCH_EXIT_TIMEOUT).then(() => "timeout" as const),
  ]);
  return result === "exited";
}

async function terminateFailedLaunch(
  proc: KillableWhisperServerProcess,
): Promise<void> {
  killWhisperProcess(proc, "SIGTERM");
  if (await waitForWhisperProcessExit(proc)) return;

  killWhisperProcess(proc, "SIGKILL");
  await waitForWhisperProcessExit(proc);
}

function isPidAlive(pid: number): boolean {
  if (testHooks.isPidAlive) return testHooks.isPidAlive(pid);
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

function killExternalPid(pid: number, signal: NodeJS.Signals): void {
  if (testHooks.killExternalPid) {
    testHooks.killExternalPid(pid, signal);
    return;
  }
  try {
    process.kill(pid, signal);
  } catch {}
}

function commandForPid(pid: number): string {
  const result = Bun.spawnSync(["ps", "-p", String(pid), "-o", "command="], {
    stdout: "pipe",
    stderr: "ignore",
  });
  if (result.exitCode !== 0) return "";
  return result.stdout.toString().trim();
}

function isWhisperServerCommand(command: string): boolean {
  const firstToken = command.trim().split(/\s+/)[0] ?? "";
  const executable = firstToken.replace(/^"(.*)"$/, "$1");
  return executable.split("/").pop() === "whisper-server";
}

function findExternalWhisperServerPids(port: number): number[] {
  if (testHooks.findExternalWhisperServerPids) {
    return testHooks.findExternalWhisperServerPids(port);
  }

  const result = Bun.spawnSync(
    ["lsof", "-nP", `-tiTCP:${port}`, "-sTCP:LISTEN"],
    { stdout: "pipe", stderr: "ignore" },
  );
  if (result.exitCode !== 0) return [];

  return result.stdout
    .toString()
    .split(/\s+/)
    .map((raw) => Number.parseInt(raw, 10))
    .filter((pid) => Number.isFinite(pid) && pid > 0)
    .filter((pid) => isWhisperServerCommand(commandForPid(pid)));
}

/**
 * PIDs listening on `port`, whatever they are — unlike
 * `findExternalWhisperServerPids` this does NOT filter by command, because the
 * question here is "is the healthy listener *our* child", not "is there a stale
 * whisper-server to reclaim".
 */
function findPortListenerPids(port: number): number[] {
  if (testHooks.findPortListenerPids) {
    return testHooks.findPortListenerPids(port);
  }
  return portOwnerPids(port, PORT_OWNER_PROBE_TIMEOUT);
}

/**
 * Is the healthy listener on `port` the child we just spawned?
 *
 * A passing health check only proves *something* answers on the port. If our
 * child lost the race (or died on startup) and another process is serving,
 * publishing `serverState`/`lastLaunchRecord` would stamp every subsequent
 * recording with a binary, args and PID that did not produce the transcript.
 *
 * Two independent signals, cheapest first:
 *  - the child has already exited (a concrete `exitCode`) — it cannot be the
 *    listener, full stop;
 *  - the PID owning the port is not ours.
 *
 * `lsof` returning nothing is treated as "cannot tell" rather than "not ours":
 * the tool may be missing or restricted, and refusing every launch on that
 * basis would be worse than the bug being fixed. The liveness check still holds
 * in that case. Fakes in tests carry no `exitCode` field at all — `undefined`
 * means unknown, not exited.
 */
function launchIsOwnedByChild(
  proc: { pid: number; exitCode?: number | null },
  port: number,
): boolean {
  if (typeof proc.exitCode === "number") return false;
  const owners = findPortListenerPids(port);
  if (owners.length === 0) return true;
  return owners.includes(proc.pid);
}

async function waitForPidExit(
  pid: number,
  timeoutMs: number,
): Promise<boolean> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (!isPidAlive(pid)) return true;
    await sleep(100);
  }
  return !isPidAlive(pid);
}

/**
 * Does an adopted server's configuration match what this process would launch?
 *
 * Deliberately narrow: model and effort tier are what actually change the
 * transcript. A mismatch is reported, never acted on.
 */
function adoptedFlagsMatch(record: {
  model_path: string;
  performance_effort: string;
}): boolean {
  const ourModel = testHooks.findModel?.() ?? findModel();
  if (record.model_path && ourModel && record.model_path !== ourModel) {
    return false;
  }
  const ourEffort = getWhisperPerformanceEffort();
  const theirEffort = parseWhisperPerformanceEffort(record.performance_effort);
  if (theirEffort && theirEffort !== ourEffort) return false;
  return true;
}

/**
 * Reuse a healthy server on `port` that this process did not launch.
 *
 * AIDEV-NOTE: This is the whole point of the ownership guard, and it is a
 * hard rule: a server that answers the health page is NEVER killed by a
 * process that did not launch it. On 2026-09-05 the old code read "healthy
 * server + my serverState is null" as "stale orphan" and SIGKILLed the live
 * daemon-owned sidecar five times in one evening. A second process cannot see
 * the first one's in-memory state; absence of *our* record is not evidence of
 * absence of *an* owner. Reclaim now belongs only to the unhealthy branch.
 */
function adoptHealthyServer(port: number): void {
  const record = readWhisperServerOwnership(port);
  const listeners = findPortListenerPids(port);

  if (record && listeners.includes(record.pid) && isPidAlive(record.pid)) {
    const flagsMatch = adoptedFlagsMatch(record);
    console.error(
      `[voicelayer] Adopting whisper-server on port ${port} (PID ${record.pid}, launched by PID ${record.owner_pid}) — not ours to restart.`,
    );
    if (!flagsMatch) {
      console.error(
        `[voicelayer] Adopted whisper-server on port ${port} was launched with different settings than this process would use (model ${record.model_path || "unknown"}, effort ${record.performance_effort || "unknown"}); using it as-is.`,
      );
    }
    serverState = { proc: null, port, pid: record.pid, adopted: true };
    lastLaunchRecord = {
      binary: record.binary,
      modelPath: record.model_path,
      args: record.args,
      performanceEffort:
        parseWhisperPerformanceEffort(record.performance_effort) ??
        getWhisperPerformanceEffort(),
      accelerationMode: normalizeAdoptedAccelerationMode(
        record.acceleration_mode,
      ),
      pid: record.pid,
      startedAt: record.started_at,
      adopted: true,
      ownerPid: record.owner_pid,
      flagsMatch,
    };
    return;
  }

  const pid = listeners[0] ?? 0;
  console.error(
    `[voicelayer] Healthy whisper-server on port ${port}${pid ? ` (PID ${pid})` : ""} has no live ownership record; adopting it rather than killing a server this process did not launch.`,
  );
  serverState = { proc: null, port, pid, adopted: true };
  // No ownership record means no provenance. Reporting the flags we *would*
  // have used would be a guess, not provenance.
  lastLaunchRecord = null;
}

function normalizeAdoptedAccelerationMode(
  value: string,
): WhisperAccelerationMode {
  return value === "metal" || value === "coreml" || value === "cpu"
    ? value
    : "cpu";
}

async function reclaimExternalWhisperServers(port: number): Promise<boolean> {
  const pids = findExternalWhisperServerPids(port);
  if (pids.length === 0) return false;

  console.error(
    `[voicelayer] Reclaiming whisper-server port ${port} from stale PID(s): ${pids.join(", ")}`,
  );
  for (const pid of pids) killExternalPid(pid, "SIGTERM");

  const termResults = await Promise.all(
    pids.map((pid) => waitForPidExit(pid, FAILED_LAUNCH_EXIT_TIMEOUT)),
  );
  for (const [index, exited] of termResults.entries()) {
    if (!exited) killExternalPid(pids[index], "SIGKILL");
  }

  await Promise.all(
    pids.map((pid) => waitForPidExit(pid, FAILED_LAUNCH_EXIT_TIMEOUT)),
  );
  return true;
}

/**
 * Ensure whisper-server is running. Starts it if needed.
 * Returns the port number.
 */
export function ensureServer(portOverride?: number): Promise<number> {
  const port =
    portOverride ||
    parseInt(process.env.QA_VOICE_WHISPER_SERVER_PORT || "", 10) ||
    DEFAULT_PORT;

  const existingLaunch = launchPromises.get(port);
  if (existingLaunch) return existingLaunch;

  const launchPromise = ensureServerUnlocked(port);
  launchPromises.set(port, launchPromise);
  const clearLaunchPromise = () => {
    if (launchPromises.get(port) === launchPromise) {
      launchPromises.delete(port);
    }
  };
  launchPromise.then(clearLaunchPromise, clearLaunchPromise);
  return launchPromise;
}

async function ensureServerUnlocked(port: number): Promise<number> {
  // Already running?
  if (serverState && serverState.port === port) {
    if (await checkServerHealthy(port)) return port;
    // Server died — clean up and restart
    console.error("[voicelayer] whisper-server died, restarting...");
    serverState = null;
    lastLaunchRecord = null;
  }

  // A healthy occupant is somebody's live server. Adopt it — never kill it,
  // never relaunch over it. Incompatible launch flags are surfaced on the
  // launch record, not resolved with a signal.
  if (await checkServerHealthy(port)) {
    adoptHealthyServer(port);
    return port;
  }

  // The port is occupied but not serving: a wedged whisper-server from a
  // crashed launch. Nothing can bind until it is gone, and it is not serving
  // anyone, so reclaiming it is safe.
  if (await reclaimExternalWhisperServers(port)) {
    if (await checkServerHealthy(port)) {
      // Something healthy appeared while we were reclaiming — adopt, do not
      // race it.
      adoptHealthyServer(port);
      return port;
    }
  }

  // Find binary and model
  const binary = testHooks.findServerBinary?.() ?? findServerBinary();
  if (!binary) {
    throw new Error(
      "whisper-server not found. Install: brew install whisper-cpp",
    );
  }

  const model = testHooks.findModel?.() ?? findModel();
  if (!model) {
    throw new Error(
      "No whisper model found. Download:\n" +
        "  curl -L -o ~/.cache/whisper/ggml-large-v3-turbo.bin \\\n" +
        "    https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin",
    );
  }

  // Get brew prefix for Metal shaders
  let metalPath: string | undefined;
  const brewBinary = resolveBinary("brew", [
    "/opt/homebrew/bin/brew",
    "/usr/local/bin/brew",
  ]);
  const brewResult = brewBinary
    ? Bun.spawnSync([brewBinary, "--prefix", "whisper-cpp"])
    : null;
  if (brewResult?.exitCode === 0) {
    metalPath = join(
      brewResult.stdout.toString().trim(),
      "share",
      "whisper-cpp",
    );
  }

  const requestedAcceleration = getRequestedAccelerationFromEnv();
  const helpProbe =
    requestedAcceleration === "coreml"
      ? (testHooks.readHelpText?.(binary) ?? readWhisperServerHelpText(binary))
      : { helpText: "" };
  if (helpProbe.warning) {
    console.error(`[voicelayer] ${helpProbe.warning}`);
  }

  // Captured ONCE, before the launch plan is built, and reused for the launch
  // record below. Re-reading the setting after the async health wait would let
  // a mid-startup settings change relabel a server that was launched with the
  // old effort.
  const launchedPerformanceEffort = getWhisperPerformanceEffort();

  const buildLaunch = (
    requestedAcceleration: WhisperAccelerationRequest,
  ): WhisperServerLaunchPlan =>
    buildWhisperServerLaunchPlan({
      binary,
      model,
      port,
      helpText: helpProbe.helpText,
      metalResourcesPath: metalPath,
      coreMLModelPath: process.env.QA_VOICE_WHISPER_COREML_MODEL,
      requestedAcceleration,
      performanceEffort: launchedPerformanceEffort,
      inheritedEnv: process.env,
    });

  let launch = buildLaunch(requestedAcceleration);

  const startLaunch = async (
    plan: WhisperServerLaunchPlan,
  ): Promise<boolean> => {
    console.error(
      `[voicelayer] Starting whisper-server on port ${port} with model ${model} (acceleration: ${plan.acceleration.mode})`,
    );
    for (const warning of plan.acceleration.warnings) {
      console.error(`[voicelayer] ${warning}`);
    }

    const proc =
      testHooks.spawn?.(plan.args, {
        stdout: "pipe",
        stderr: "pipe",
        env: plan.env,
      }) ??
      Bun.spawn(plan.args, {
        stdout: "pipe",
        stderr: "pipe",
        env: plan.env,
      });

    // Drain stderr in background (server logs)
    if (proc.stderr) {
      const reader = (proc.stderr as ReadableStream<Uint8Array>).getReader();
      (async () => {
        try {
          while (true) {
            const { done } = await reader.read();
            if (done) break;
          }
        } catch {}
      })();
    }

    // Wait for server to become healthy
    const startupTimeoutMs = getStartupTimeoutMs();
    const deadline = Date.now() + startupTimeoutMs;
    while (Date.now() < deadline) {
      if (await checkServerHealthy(port)) {
        // Healthy is not the same as ours. Publishing an unowned listener would
        // stamp every recording with a binary/args/PID that did not produce it.
        if (!launchIsOwnedByChild(proc, port)) {
          console.error(
            `[voicelayer] Port ${port} is served by another process, not our whisper-server child (PID ${proc.pid}); not adopting it.`,
          );
          break;
        }
        // One instant for both the launch record and the on-disk ownership
        // record: a reader that compares them must not see them disagree.
        const startedAt = new Date().toISOString();
        serverState = {
          proc: proc as WhisperServerProcess,
          port,
          pid: proc.pid,
          adopted: false,
        };
        lastLaunchRecord = {
          binary,
          modelPath: model,
          args: plan.args,
          performanceEffort: launchedPerformanceEffort,
          accelerationMode: plan.acceleration.mode,
          pid: proc.pid,
          startedAt,
        };
        // Tell every other process on this machine who owns this server, so
        // none of them mistakes it for an orphan and kills it.
        writeWhisperServerOwnership(port, {
          pid: proc.pid,
          owner_pid: process.pid,
          started_at: startedAt,
          binary,
          args: plan.args,
          model_path: model,
          performance_effort: launchedPerformanceEffort,
          acceleration_mode: plan.acceleration.mode,
        });
        console.error(
          `[voicelayer] whisper-server ready (PID ${proc.pid}, port ${port})`,
        );
        return true;
      }
      await sleep(500);
    }

    // Timeout — kill and report failure to caller.
    await terminateFailedLaunch(proc);
    return false;
  };

  if (await startLaunch(launch)) return port;

  if (launch.acceleration.mode === "coreml") {
    console.error(
      "[voicelayer] whisper-server Core ML startup failed; retrying with Metal fallback.",
    );
    launch = buildLaunch("metal");
    if (await startLaunch(launch)) return port;
  }

  throw new Error(
    `whisper-server failed to start within ${getStartupTimeoutMs() / 1000}s`,
  );
}

/**
 * Stop the whisper-server sidecar this process launched.
 *
 * AIDEV-NOTE: This runs on `process.on("exit")`, which makes it a kill path
 * for anything that adopted a server it does not own — a `bun test` run that
 * touched ensureServer() would otherwise take down Etan's live sidecar on the
 * way out. An adopted server is detached from, never signalled.
 */
export function stopServer(): void {
  launchPromises.clear();
  if (!serverState) return;

  const state = serverState;
  serverState = null;
  lastLaunchRecord = null;

  if (state.adopted || !state.proc) {
    console.error(
      `[voicelayer] Detaching from adopted whisper-server (PID ${state.pid}) — this process did not launch it.`,
    );
    return;
  }

  console.error(`[voicelayer] Stopping whisper-server (PID ${state.pid})`);
  try {
    state.proc.kill();
  } catch {}
  clearWhisperServerOwnership(state.port);
}

configureWhisperPerformanceRestart(stopServer);

/**
 * Transcribe a WAV audio buffer via whisper-server HTTP API.
 *
 * @param wavData - Complete WAV file as Uint8Array (with header)
 * @returns Transcription text (may be empty for silence)
 */
/** Inference timeout: 8s per request (generous for 3s audio windows). */
const INFERENCE_TIMEOUT = 8000;

export interface WhisperServerTranscribeOptions {
  language?: string;
  prompt?: string;
  /**
   * Opt in to segment timestamps. Set ONLY under
   * `VOICELAYER_STT_SMART_BOUNDARIES=1` (`src/stt-sentence-boundaries.ts`):
   * it switches the request to `response_format=verbose_json`, so with the flag
   * off the request stays byte-for-byte the shipped `json` one.
   *
   * AIDEV-NOTE: verbose_json also carries per-word times. Do NOT use them —
   * measured on `2026-09-06T12-56-44-855Z-28f3916c` they interpolate straight
   * across silence (whisper claims speech through a window whose RMS is -60 dB).
   * Segment ends are the trustworthy field, to ~0.15 s.
   */
  onSegments?: (segments: TranscriptSegment[]) => void;
}

/** Parsed `segments[]` from a `verbose_json` inference response. */
function parseVerboseSegments(payload: unknown): TranscriptSegment[] {
  if (!payload || typeof payload !== "object") return [];
  const raw = (payload as { segments?: unknown }).segments;
  if (!Array.isArray(raw)) return [];
  const segments: TranscriptSegment[] = [];
  for (const entry of raw) {
    if (!entry || typeof entry !== "object") continue;
    const { text, start, end } = entry as {
      text?: unknown;
      start?: unknown;
      end?: unknown;
    };
    if (
      typeof text !== "string" ||
      typeof start !== "number" ||
      typeof end !== "number" ||
      !Number.isFinite(start) ||
      !Number.isFinite(end)
    ) {
      continue;
    }
    segments.push({ text, startS: start, endS: end });
  }
  return segments;
}

export async function transcribeViaServer(
  wavData: Uint8Array,
  port?: number,
  options?: WhisperServerTranscribeOptions,
): Promise<string> {
  return transcribeViaServerAttempt(wavData, port, true, options);
}

function normalizeTranscriptionText(text: string): string {
  return text
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean)
    .join(" ")
    .trim();
}

async function transcribeViaServerAttempt(
  wavData: Uint8Array,
  port: number | undefined,
  allowRetry: boolean,
  options?: WhisperServerTranscribeOptions,
): Promise<string> {
  const serverPort = port ?? (await ensureServer());

  const formData = new FormData();
  formData.append(
    "file",
    new Blob([wavData as BlobPart], { type: "audio/wav" }),
    "audio.wav",
  );
  formData.append(
    "response_format",
    options?.onSegments ? "verbose_json" : "json",
  );
  formData.append("temperature", "0.0");
  if (options?.language) {
    formData.append("language", options.language);
  }
  if (options?.prompt) {
    formData.append("prompt", options.prompt);
  }

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), INFERENCE_TIMEOUT);
  try {
    let resp: Response;
    try {
      resp = await fetch(`http://127.0.0.1:${serverPort}/inference`, {
        method: "POST",
        body: formData,
        signal: controller.signal,
      });
    } catch (err) {
      if (allowRetry) {
        await markServerUnhealthy();
        const retryPort = await ensureServer(port);
        return transcribeViaServerAttempt(wavData, retryPort, false, options);
      }
      throw err;
    }

    if (!resp.ok) {
      if (allowRetry && resp.status >= 500) {
        await markServerUnhealthy();
        const retryPort = await ensureServer(port);
        return transcribeViaServerAttempt(wavData, retryPort, false, options);
      }
      throw new Error(
        `whisper-server inference failed: ${resp.status} ${resp.statusText}`,
      );
    }

    const result = (await resp.json()) as { text?: string; error?: string };
    if (result.error) {
      throw new Error(`whisper-server inference error: ${result.error}`);
    }
    // Segments are advisory: a response without them still transcribes, the
    // boundary stage just gets nothing to judge and leaves the text alone.
    options?.onSegments?.(parseVerboseSegments(result));
    return normalizeTranscriptionText(result.text || "");
  } finally {
    clearTimeout(timer);
  }
}

async function markServerUnhealthy(): Promise<void> {
  if (!serverState) return;
  const unhealthyState = serverState;
  serverState = null;
  lastLaunchRecord = null;
  // An adopted server is not ours to terminate, however sick it looks: the
  // process that launched it owns its lifecycle. Drop our reference instead.
  if (unhealthyState.adopted || !unhealthyState.proc) return;
  await terminateFailedLaunch(unhealthyState.proc);
  clearWhisperServerOwnership(unhealthyState.port);
}

export function __resetWhisperServerStateForTests(
  state: WhisperServerState | null,
): void {
  serverState = state;
  launchPromises.clear();
}

/** Check if whisper-server binary is available (for feature detection). */
export function isServerAvailable(): boolean {
  return findServerBinary() !== null && findModel() !== null;
}

// Clean up on process exit
process.on("exit", stopServer);
process.on("SIGTERM", () => {
  stopServer();
  process.exit(0);
});
process.on("SIGINT", () => {
  stopServer();
  process.exit(0);
});
