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
  | { status: "already-ready" | "ready" | "starting"; pid?: number };

export interface EnsureSTTPolishServerOptions {
  env?: STTPolishEnv;
  findBinary?: () => string | null;
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
  if (getSTTPolishMode(env) === "off") return { status: "disabled" };
  if (endpoint !== DEFAULT_POLISH_ENDPOINT) return { status: "external" };

  if (await isReady(endpoint, options)) {
    return { status: "already-ready", pid: polishProcess?.pid };
  }

  if (polishLaunch) return polishLaunch;
  polishLaunch = startAndWaitForPolishServer(endpoint, options).finally(() => {
    polishLaunch = null;
  });
  return polishLaunch;
}

async function startAndWaitForPolishServer(
  endpoint: string,
  options: EnsureSTTPolishServerOptions,
): Promise<STTPolishServerStatus> {
  const appendEvent = options.appendEvent ?? appendControlLayerEvent;
  const log = options.log ?? console.error;
  const binary = options.findBinary?.() ?? findPolishServerBinary();

  if (!binary) {
    appendEvent(
      "transcription.polish_server_missing_binary",
      { endpoint },
      { topic: "voice.transcription" },
    );
    return { status: "missing-binary" };
  }

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
    { endpoint, model: DEFAULT_POLISH_MODEL, port: DEFAULT_POLISH_PORT },
    { topic: "voice.transcription" },
  );
  log(
    `[voicelayer] Starting STT polish server on ${DEFAULT_POLISH_HOST}:${DEFAULT_POLISH_PORT} with model ${DEFAULT_POLISH_MODEL}`,
  );

  const proc = spawnPolishServer(args, options);
  polishProcess = proc;
  drainPolishServerLogs(proc, log);

  const timeoutMs = options.startupTimeoutMs ?? DEFAULT_STARTUP_TIMEOUT_MS;
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await isReady(endpoint, options)) {
      appendEvent(
        "transcription.polish_server_ready",
        { endpoint, model: DEFAULT_POLISH_MODEL, port: DEFAULT_POLISH_PORT, pid: proc.pid },
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
      port: DEFAULT_POLISH_PORT,
      pid: proc.pid,
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

function findPolishServerBinary(): string | null {
  return resolveBinary("mlx_lm.server", [
    "/Library/Frameworks/Python.framework/Versions/3.13/bin/mlx_lm.server",
    "/opt/homebrew/bin/mlx_lm.server",
    "/usr/local/bin/mlx_lm.server",
  ]);
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
): void {
  if (!proc.stderr) return;
  const reader = proc.stderr.getReader();
  void (async () => {
    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        const text = new TextDecoder().decode(value).trim();
        if (text) log(`[voicelayer-polish] ${text}`);
      }
    } catch {}
  })();
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
