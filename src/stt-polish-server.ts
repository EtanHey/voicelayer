import { accessSync, constants } from "fs";

import { resolveBinary } from "./resolve-binary";
import { appendControlLayerEvent } from "./control-layer-journal";
import {
  DEFAULT_POLISH_ENDPOINT,
  DEFAULT_POLISH_MODEL,
  getSTTPolishEndpoint,
  getSTTPolishMode,
  type STTPolishEnv,
} from "./stt-polish";

type ManagedPolishProcess = {
  pid: number;
  kill?: (signal?: NodeJS.Signals) => void;
  exited?: Promise<number>;
  stderr?: ReadableStream<Uint8Array> | null;
};

type StderrTail = {
  text: string;
};

type SpawnPolishProcess = (
  args: string[],
  options: {
    stdout: "pipe";
    stderr: "pipe";
    env: Record<string, string>;
  },
) => ManagedPolishProcess;

export type STTPolishServerStatus =
  | { status: "disabled" | "external" | "missing-binary" | "timeout" }
  | { status: "launch-failed"; error: string }
  | { status: "already-ready" | "ready" | "starting"; pid?: number };

export interface EnsureSTTPolishServerOptions {
  env?: STTPolishEnv;
  forceRestart?: boolean;
  findBinary?: () => string | null;
  findPortOwnerPids?: () => number[];
  findStalePortOwnerPids?: () => number[];
  killProcess?: (pid: number, signal?: NodeJS.Signals) => void;
  isEndpointReady?: (endpoint: string) => Promise<boolean>;
  spawn?: SpawnPolishProcess;
  appendEvent?: (
    type: string,
    payload: Record<string, unknown>,
    options?: { topic?: string; seat?: string | null },
  ) => void;
  sleep?: (ms: number) => Promise<void>;
  startupTimeoutMs?: number;
  log?: (message: string) => void;
}

const DEFAULT_POLISH_HOST = "127.0.0.1";
const DEFAULT_POLISH_PORT = 8080;
const DEFAULT_STARTUP_TIMEOUT_MS = 120_000;

let polishProcess: ManagedPolishProcess | null = null;
let polishLaunch: Promise<STTPolishServerStatus> | null = null;
const polishStatusListeners = new Set<(status: STTPolishServerStatus) => void>();

export function onSTTPolishServerStatus(
  listener: (status: STTPolishServerStatus) => void,
): () => void {
  polishStatusListeners.add(listener);
  return () => polishStatusListeners.delete(listener);
}

function publishSTTPolishServerStatus(
  status: STTPolishServerStatus,
): STTPolishServerStatus {
  for (const listener of polishStatusListeners) listener(status);
  return status;
}

export function resetSTTPolishServerManagerForTests(): void {
  polishLaunch = null;
  if (polishProcess?.kill) {
    try {
      polishProcess.kill("SIGTERM");
    } catch {}
  }
  polishProcess = null;
}

export function stopSTTPolishServer(): void {
  resetSTTPolishServerManagerForTests();
}

export async function ensureSTTPolishServer(
  options: EnsureSTTPolishServerOptions = {},
): Promise<STTPolishServerStatus> {
  const env = options.env ?? process.env;
  const endpoint = getSTTPolishEndpoint(env);
  if (getSTTPolishMode(env) === "off") {
    return publishSTTPolishServerStatus({ status: "disabled" });
  }
  if (endpoint !== DEFAULT_POLISH_ENDPOINT) {
    return publishSTTPolishServerStatus({ status: "external" });
  }

  if (!options.forceRestart && await isReady(endpoint, options)) {
    return publishSTTPolishServerStatus({
      status: "already-ready",
      pid: polishProcess?.pid,
    });
  }

  if (polishLaunch) return polishLaunch.then(publishSTTPolishServerStatus);
  polishLaunch = startAndWaitForPolishServer(endpoint, options).finally(() => {
    polishLaunch = null;
  });
  return polishLaunch.then(publishSTTPolishServerStatus);
}

export function recoverDefaultSTTPolishServerAfterFailure(
  env: STTPolishEnv = process.env,
  options: Omit<EnsureSTTPolishServerOptions, "env" | "forceRestart"> = {},
): void {
  if (getSTTPolishMode(env) === "off") return;
  if (getSTTPolishEndpoint(env) !== DEFAULT_POLISH_ENDPOINT) return;
  void ensureSTTPolishServer({ ...options, env, forceRestart: true }).catch((error: unknown) => {
    const detail = error instanceof Error ? error.message : String(error);
    console.error(
      `[voicelayer] STT polish server recovery failed: ${detail}`,
    );
    publishSTTPolishServerStatus({ status: "launch-failed", error: detail });
  });
}

async function startAndWaitForPolishServer(
  endpoint: string,
  options: EnsureSTTPolishServerOptions,
): Promise<STTPolishServerStatus> {
  const appendEvent = options.appendEvent ?? appendControlLayerEvent;
  const log = options.log ?? console.error;
  const binary = options.findBinary
    ? options.findBinary()
    : findPolishServerBinary();

  if (!binary) {
    appendEvent(
      "transcription.polish_server_missing_binary",
      { endpoint },
      { topic: "voice.transcription" },
    );
    return { status: "missing-binary" };
  }

  await reapStaleDefaultPolishPortOwners(options, appendEvent);

  const args = [
    binary,
    "--model",
    DEFAULT_POLISH_MODEL,
    "--host",
    DEFAULT_POLISH_HOST,
    "--port",
    String(DEFAULT_POLISH_PORT),
  ];
  appendEvent(
    "transcription.polish_server_starting",
    {
      endpoint,
      model: DEFAULT_POLISH_MODEL,
      host: DEFAULT_POLISH_HOST,
      port: DEFAULT_POLISH_PORT,
      binary,
      timeout_ms: options.startupTimeoutMs ?? DEFAULT_STARTUP_TIMEOUT_MS,
    },
    { topic: "voice.transcription" },
  );
  log(
    `[voicelayer] Starting STT polish server on ${DEFAULT_POLISH_HOST}:${DEFAULT_POLISH_PORT} with model ${DEFAULT_POLISH_MODEL}`,
  );

  const proc = spawnPolishServer(args, options);
  polishProcess = proc;
  const stderrTail = drainPolishServerLogs(proc, log);

  const timeoutMs = options.startupTimeoutMs ?? DEFAULT_STARTUP_TIMEOUT_MS;
  const deadline = Date.now() + timeoutMs;
  let readinessChecks = 0;
  while (Date.now() < deadline) {
    readinessChecks++;
    if (
      (await isReady(endpoint, options)) &&
      isSpawnedPolishProcessServingPort(proc, options)
    ) {
      appendEvent(
        "transcription.polish_server_ready",
        {
          endpoint,
          model: DEFAULT_POLISH_MODEL,
          host: DEFAULT_POLISH_HOST,
          port: DEFAULT_POLISH_PORT,
          binary,
          pid: proc.pid,
          readiness_checks: readinessChecks,
          stderr_tail: stderrTail.text || null,
        },
        { topic: "voice.transcription" },
      );
      return { status: "ready", pid: proc.pid };
    }
    await (options.sleep ?? Bun.sleep)(500);
  }

  appendEvent(
    "transcription.polish_server_timeout",
    {
      endpoint,
      model: DEFAULT_POLISH_MODEL,
      host: DEFAULT_POLISH_HOST,
      port: DEFAULT_POLISH_PORT,
      binary,
      pid: proc.pid,
      readiness_checks: readinessChecks,
      stderr_tail: stderrTail.text || null,
      timeout_ms: timeoutMs,
    },
    { topic: "voice.transcription" },
  );
  terminatePolishProcess(proc);
  if (polishProcess === proc) {
    polishProcess = null;
  }
  return { status: "timeout" };
}

async function reapStaleDefaultPolishPortOwners(
  options: EnsureSTTPolishServerOptions,
  appendEvent: NonNullable<EnsureSTTPolishServerOptions["appendEvent"]>,
): Promise<void> {
  const pids = getStaleDefaultPolishPortOwnerPids(options);
  const currentManagedPid = polishProcess?.pid;
  const reapablePids = [...new Set(pids)].filter(
    (pid) => Number.isInteger(pid) && pid > 0 && pid !== process.pid,
  );
  if (reapablePids.length === 0) return;

  const killProcess = options.killProcess ?? process.kill;
  const killed: number[] = [];
  for (const pid of reapablePids) {
    try {
      killProcess(pid, "SIGTERM");
      killed.push(pid);
      if (pid === currentManagedPid) polishProcess = null;
    } catch {}
  }
  if (killed.length === 0) return;

  appendEvent(
    "transcription.polish_server_stale_owner_reaped",
    { port: DEFAULT_POLISH_PORT, pids: killed },
    { topic: "voice.transcription" },
  );
  await (options.sleep ?? Bun.sleep)(500);
}

function getStaleDefaultPolishPortOwnerPids(
  options: EnsureSTTPolishServerOptions,
): number[] {
  if (options.findStalePortOwnerPids) return options.findStalePortOwnerPids();

  const hasTestHooks =
    options.findBinary !== undefined ||
    options.isEndpointReady !== undefined ||
    options.spawn !== undefined ||
    options.killProcess !== undefined;
  if (hasTestHooks) return [];

  return findDefaultPolishPortOwnerPids();
}

function findDefaultPolishPortOwnerPids(): number[] {
  return findDefaultPolishPortOwnerPidsUnfiltered().filter((pid) =>
    isPolishServerPid(pid),
  );
}

function findDefaultPolishPortOwnerPidsUnfiltered(): number[] {
  const result = Bun.spawnSync(
    ["lsof", "-nP", `-iTCP:${DEFAULT_POLISH_PORT}`, "-sTCP:LISTEN", "-t"],
    { stdout: "pipe", stderr: "pipe" },
  );
  if (result.exitCode !== 0) return [];
  return new TextDecoder()
    .decode(result.stdout)
    .split(/\s+/u)
    .map((value) => Number(value))
    .filter((pid) => Number.isInteger(pid) && pid > 0);
}

function isPolishServerPid(pid: number): boolean {
  const result = Bun.spawnSync(["ps", "-p", String(pid), "-o", "command="], {
    stdout: "pipe",
    stderr: "pipe",
  });
  if (result.exitCode !== 0) return false;
  const command = new TextDecoder().decode(result.stdout);
  return (
    command.includes("mlx_lm.server") &&
    new RegExp(`--port(?:=|\\s+)${DEFAULT_POLISH_PORT}(?:\\s|$)`, "u").test(command)
  );
}

function isSpawnedPolishProcessServingPort(
  proc: ManagedPolishProcess,
  options: EnsureSTTPolishServerOptions,
): boolean {
  const owners = getDefaultPolishPortOwnerPids(options);
  return owners.includes(proc.pid);
}

function getDefaultPolishPortOwnerPids(
  options: EnsureSTTPolishServerOptions,
): number[] {
  if (options.findPortOwnerPids) return options.findPortOwnerPids();

  const hasTestHooks =
    options.findBinary !== undefined ||
    options.isEndpointReady !== undefined ||
    options.spawn !== undefined ||
    options.killProcess !== undefined ||
    options.findStalePortOwnerPids !== undefined;
  if (hasTestHooks) return polishProcess?.pid ? [polishProcess.pid] : [];

  return findDefaultPolishPortOwnerPidsUnfiltered();
}

function findPolishServerBinary(): string | null {
  const knownCandidates = [
    "/Library/Frameworks/Python.framework/Versions/3.13/bin/mlx_lm.server",
    "/opt/homebrew/bin/mlx_lm.server",
    "/usr/local/bin/mlx_lm.server",
  ];
  for (const candidate of knownCandidates) {
    if (isExecutableFile(candidate)) return candidate;
  }
  return resolveBinary("mlx_lm.server");
}

function isExecutableFile(path: string): boolean {
  try {
    accessSync(path, constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

function spawnPolishServer(
  args: string[],
  options: EnsureSTTPolishServerOptions,
): ManagedPolishProcess {
  const env: Record<string, string> = {};
  for (const [key, value] of Object.entries(options.env ?? process.env)) {
    if (typeof value === "string") env[key] = value;
  }
  return (
    options.spawn?.(args, { stdout: "pipe", stderr: "pipe", env }) ??
    Bun.spawn(args, { stdout: "pipe", stderr: "pipe", env })
  );
}

function drainPolishServerLogs(
  proc: ManagedPolishProcess,
  log: (message: string) => void,
): StderrTail {
  const tail: StderrTail = { text: "" };
  if (!proc.stderr) return tail;
  const reader = proc.stderr.getReader();
  void (async () => {
    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        const text = new TextDecoder().decode(value).trim();
        if (text) {
          tail.text = `${tail.text}\n${text}`.trim().slice(-2_000);
          log(`[voicelayer-polish] ${text}`);
        }
      }
    } catch {}
  })();
  return tail;
}

function terminatePolishProcess(proc: ManagedPolishProcess): void {
  try {
    proc.kill?.("SIGTERM");
  } catch {}
}

async function isReady(
  endpoint: string,
  options: EnsureSTTPolishServerOptions,
): Promise<boolean> {
  if (options.isEndpointReady) return options.isEndpointReady(endpoint);
  const url = endpoint.replace(/\/v1\/chat\/completions\/?$/u, "/v1/models");
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 1_500);
  try {
    const response = await fetch(url, { signal: controller.signal });
    return response.ok;
  } catch {
    return false;
  } finally {
    clearTimeout(timeout);
  }
}
