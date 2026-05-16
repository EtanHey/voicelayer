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
import { resolveBinary } from "./resolve-binary";

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
  proc: ReturnType<typeof Bun.spawn>;
  port: number;
  pid: number;
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

function normalizeAccelerationRequest(value?: string): WhisperAccelerationRequest {
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
    "-nt", // no timestamps
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
  }

  // Port 8178 is reserved for the daemon-owned VoiceLayer sidecar. Do not
  // silently reuse stale orphan servers: they can have incompatible launch
  // flags while still answering the health page.
  if (await checkServerHealthy(port)) {
    if (await reclaimExternalWhisperServers(port)) {
      if (await checkServerHealthy(port)) {
        throw new Error(
          `whisper-server port ${port} is still occupied after reclaim attempt`,
        );
      }
    } else {
      throw new Error(
        `whisper-server port ${port} is already occupied by a non-VoiceLayer process`,
      );
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
        serverState = {
          proc: proc as WhisperServerProcess,
          port,
          pid: proc.pid,
        };
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

/** Stop the whisper-server sidecar. */
export function stopServer(): void {
  launchPromises.clear();
  if (serverState) {
    console.error(
      `[voicelayer] Stopping whisper-server (PID ${serverState.pid})`,
    );
    try {
      serverState.proc.kill();
    } catch {}
    serverState = null;
  }
}

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
}

export async function transcribeViaServer(
  wavData: Uint8Array,
  port?: number,
  options?: WhisperServerTranscribeOptions,
): Promise<string> {
  return transcribeViaServerAttempt(wavData, port, true, options);
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
  formData.append("response_format", "json");
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
    return (result.text || "").trim();
  } finally {
    clearTimeout(timer);
  }
}

async function markServerUnhealthy(): Promise<void> {
  if (!serverState) return;
  const unhealthyState = serverState;
  serverState = null;
  await terminateFailedLaunch(unhealthyState.proc);
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
