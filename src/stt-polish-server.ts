import { accessSync, constants } from "fs";

import { processingEnv } from "./processing-settings";
import { resolveBinary } from "./resolve-binary";
import { appendControlLayerEvent } from "./control-layer-journal";
import {
  DEFAULT_POLISH_ENDPOINT,
  DEFAULT_POLISH_MODEL,
  getSTTPolishEndpoint,
  getSTTPolishMode,
  type STTPolishEnv,
  type STTPolishFailureKind,
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
  /**
   * Is this process the machine's resident stack? An isolated harness must never
   * reap the live polish server (see the note on the reaper). Defaults to the
   * socket-override check; tests inject it so they are not at the mercy of the
   * preload's own isolation.
   */
  isResidentStack?: () => boolean;
  env?: STTPolishEnv;
  forceRestart?: boolean;
  isProcessAlive?: (pid: number) => boolean;
  stopExitTimeoutMs?: number;
  ownerWatchIntervalMs?: number;
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
import { isDefaultVoiceBarSocketPath } from "./paths";

const DEFAULT_POLISH_PORT = 8080;
const DEFAULT_STARTUP_TIMEOUT_MS = 120_000;

let polishProcess: ManagedPolishProcess | null = null;
let polishLaunch: Promise<STTPolishServerStatus> | null = null;
const reapedOwnerPids = new Set<number>();
let ownerWatch: { pid: number; timer?: ReturnType<typeof setTimeout> } | null = null;
/**
 * Bumped by every stop. A launch captures it at start and re-checks it after
 * each await: a stale launch spawns nothing more, terminates what it spawned,
 * and its result is never published (P1 #146 round 2, Polish off mid-load).
 */
let polishGeneration = 0;
const POLISH_STOP_EXIT_TIMEOUT_MS = 1_500;
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

function resetSTTPolishServerManager(retainReapedOwners: boolean): void {
  if (!retainReapedOwners) reapedOwnerPids.clear();
  polishGeneration++;
  if (ownerWatch?.timer) clearTimeout(ownerWatch.timer);
  ownerWatch = null;
  polishLaunch = null;
  if (polishProcess?.kill) {
    try {
      polishProcess.kill("SIGTERM");
    } catch {}
  }
  polishProcess = null;
}

export function resetSTTPolishServerManagerForTests(): void {
  resetSTTPolishServerManager(false);
}

export function stopSTTPolishServer(): void {
  resetSTTPolishServerManager(true);
}

/**
 * Stop the polish server this process launched and WAIT for it to exit
 * (SIGKILL after a timeout), so a following "on" never finds the dying server
 * still answering and reports it ready. Cancels any in-flight launch.
 */
export async function stopSTTPolishServerAndWait(): Promise<void> {
  const proc = polishProcess;
  resetSTTPolishServerManager(true);
  if (proc) await escalatePolishProcessExit(proc, POLISH_STOP_EXIT_TIMEOUT_MS);
}

export async function ensureSTTPolishServer(
  options: EnsureSTTPolishServerOptions = {},
): Promise<STTPolishServerStatus> {
  const env = options.env ?? processingEnv();
  const endpoint = getSTTPolishEndpoint(env);
  if (getSTTPolishMode(env) === "off") {
    if (ownerWatch?.timer) clearTimeout(ownerWatch.timer);
    ownerWatch = null;
    return publishSTTPolishServerStatus({ status: "disabled" });
  }
  if (endpoint !== DEFAULT_POLISH_ENDPOINT) {
    if (ownerWatch?.timer) clearTimeout(ownerWatch.timer);
    ownerWatch = null;
    return publishSTTPolishServerStatus({ status: "external" });
  }

  const generation = polishGeneration;
  if (polishLaunch) return polishLaunch;
  const ready = await isReady(endpoint, options);
  if (generation !== polishGeneration) return { status: "disabled" };
  // Explicit user recovery reaps only an unready filtered MLX owner.
  if (ready) {
    if (ownerWatch?.timer) clearTimeout(ownerWatch.timer);
    ownerWatch = null;
    return publishSTTPolishServerStatus({
      status: "already-ready",
      pid: polishProcess?.pid,
    });
  }

  // A slow health probe is not proof of death. Preserve an existing owner,
  // including a managed child still loading before it binds the port.
  if (!options.forceRestart && !polishLaunch) {
    const pid = existingPolishOwner(options);
    if (pid) return publishSTTPolishServerStatus(watchPolishOwner(endpoint, pid, options, generation));
  }

  const publishIfCurrent = (status: STTPolishServerStatus) =>
    generation === polishGeneration ? publishSTTPolishServerStatus(status) : status;
  // Another caller may have launched while the health probe awaited.
  const pending = polishLaunch as Promise<STTPolishServerStatus> | null;
  if (pending) return pending.then(publishIfCurrent);
  // Compare against the TRACKED promise: a settled launch must be cleared, or a
  // later explicit forceRestart would reuse its stale result and never
  // relaunch (#146 round 3).
  const tracked: Promise<STTPolishServerStatus> = startAndWaitForPolishServer(
    endpoint,
    options,
    generation,
  ).finally(() => {
    if (polishLaunch === tracked) polishLaunch = null;
  });
  polishLaunch = tracked;
  return tracked.then(publishIfCurrent);
}

export function recoverDefaultSTTPolishServerAfterFailure(
  env: STTPolishEnv = processingEnv(),
  options: Omit<EnsureSTTPolishServerOptions, "env" | "forceRestart"> & {
    failureKind?: STTPolishFailureKind;
  } = {},
): void {
  if (!options.failureKind || options.failureKind === "timeout" || options.failureKind === "endpoint-error") return;
  if (getSTTPolishMode(env) === "off") return;
  if (getSTTPolishEndpoint(env) !== DEFAULT_POLISH_ENDPOINT) return;
  void ensureSTTPolishServer({ ...options, env }).catch((error: unknown) => {
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
  generation: number,
): Promise<STTPolishServerStatus> {
  const cancelled = () => generation !== polishGeneration;
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

  if (options.forceRestart) await reapStaleDefaultPolishPortOwners(options, appendEvent);
  if (cancelled()) return { status: "disabled" };

  // Even an explicit restart must wait for the previous owner to exit.
  const existingPid = existingPolishOwner(options);
  if (existingPid) return watchPolishOwner(endpoint, existingPid, options, generation);

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

  if (ownerWatch?.timer) clearTimeout(ownerWatch.timer);
  ownerWatch = null;
  const proc = spawnPolishServer(args, options);
  polishProcess = proc;
  // Retain custody until exit is observed, including after a startup timeout.
  void proc.exited?.then(
    () => { if (polishProcess === proc) polishProcess = null; },
    () => {},
  );
  const abandon = (): STTPolishServerStatus => {
    terminatePolishProcess(proc);
    if (polishProcess === proc) polishProcess = null;
    return { status: "disabled" };
  };
  const stderrTail = drainPolishServerLogs(proc, log);

  const timeoutMs = options.startupTimeoutMs ?? DEFAULT_STARTUP_TIMEOUT_MS;
  const deadline = Date.now() + timeoutMs;
  let readinessChecks = 0;
  while (Date.now() < deadline) {
    if (cancelled()) return abandon();
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
  if (cancelled()) return abandon();

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
  await escalatePolishProcessExit(proc, options.stopExitTimeoutMs ?? POLISH_STOP_EXIT_TIMEOUT_MS, options);
  return { status: "timeout" };
}

async function reapStaleDefaultPolishPortOwners(
  options: EnsureSTTPolishServerOptions,
  appendEvent: NonNullable<EnsureSTTPolishServerOptions["appendEvent"]>,
): Promise<void> {
  // AIDEV-NOTE: An isolated harness must never reap the machine's live polish server.
  //
  // `corpus-replay-verify.ts` isolates sockets, roots and the whisper port, but the
  // polish port is shared. So a harness daemon ran this reaper against the LIVE 8080
  // and SIGTERMed the resident polish server. On 2026-09-08 two of my own release-gate
  // runs killed Etan's polish mid-session that way, and because the daemon only ensures
  // polish at startup (`mcp-server-daemon.ts:215`) it stayed dead until the child was
  // restarted — every dictation in between shipped unpolished.
  //
  // The discriminator is the one a harness cannot fake and cannot forget: it always
  // overrides the socket path, and `corpus-replay-verify.ts:79-82` refuses the live
  // sockets outright. CI has no override, so CI still reaps normally.
  if (!(options.isResidentStack ?? isDefaultVoiceBarSocketPath)()) return;

  const pids = getStaleDefaultPolishPortOwnerPids(options);
  const reapablePids = [...new Set(pids)].filter(
    (pid) => Number.isInteger(pid) && pid > 0 && pid !== process.pid,
  );
  if (reapablePids.length === 0) return;

  const killProcess = options.killProcess ?? process.kill;
  const killed: number[] = [];
  for (const pid of reapablePids) {
    reapedOwnerPids.add(pid);
    try {
      killProcess(pid, "SIGTERM");
      killed.push(pid);
      // Reaping is an explicit user action. Wait for the exact owner to exit
      // before the duplicate-owner guard decides whether a replacement is safe.
      const proc = polishProcess?.pid === pid ? polishProcess : {
        pid,
        kill: (signal: NodeJS.Signals = "SIGTERM") => {
          // A reused PID must not turn escalation into an unrelated-process kill.
          if (signal === "SIGKILL" && !options.killProcess && !isPolishServerPid(pid)) return;
          killProcess(pid, signal);
        },
      };
      await escalatePolishProcessExit(proc, options.stopExitTimeoutMs ?? POLISH_STOP_EXIT_TIMEOUT_MS, options);
    } catch {}
    if (!isPolishProcessAlive(pid, options)) reapedOwnerPids.delete(pid);
  }
  if (killed.length === 0) return;

  appendEvent(
    "transcription.polish_server_stale_owner_reaped",
    { port: DEFAULT_POLISH_PORT, pids: killed },
    { topic: "voice.transcription" },
  );
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

function existingPolishOwner(options: EnsureSTTPolishServerOptions): number | undefined {
  if (polishProcess) {
    if (isPolishProcessAlive(polishProcess.pid, options)) return polishProcess.pid;
    polishProcess = null;
  }
  // A terminating orphan can release its port before releasing its model.
  for (const pid of reapedOwnerPids) {
    if (isPolishProcessAlive(pid, options)) return pid;
    reapedOwnerPids.delete(pid);
  }
  return getDefaultPolishPortOwnerPids(options)[0];
}

function isPolishProcessAlive(pid: number, options: EnsureSTTPolishServerOptions = {}): boolean {
  if (options.isProcessAlive) return options.isProcessAlive(pid);
  try { process.kill(pid, 0); return true; } catch (error) {
    return (error as NodeJS.ErrnoException).code !== "ESRCH";
  }
}

function watchPolishOwner(endpoint: string, pid: number, options: EnsureSTTPolishServerOptions, generation: number): STTPolishServerStatus {
  if (ownerWatch && ownerWatch.pid !== pid) { clearTimeout(ownerWatch.timer); ownerWatch = null; }
  if (!ownerWatch) {
    const watch: { pid: number; timer?: ReturnType<typeof setTimeout> } = { pid };
    let degraded = false;
    const arm = (ms: number) => {
      watch.timer = setTimeout(check, ms);
      watch.timer.unref?.();
    };
    const check = async () => {
      if (generation !== polishGeneration || ownerWatch !== watch) return;
      const alive = isPolishProcessAlive(pid, options);
      const ready = alive && await isReady(endpoint, options).catch(() => false);
      if (generation !== polishGeneration || ownerWatch !== watch) return;
      if (ready) {
        ownerWatch = null;
        publishSTTPolishServerStatus({ status: "already-ready", pid });
        return;
      }
      if (!degraded) { degraded = true; publishSTTPolishServerStatus({ status: "timeout" }); }
      if (!alive) { ownerWatch = null; return; }
      arm(options.ownerWatchIntervalMs ?? 5_000);
    };
    ownerWatch = watch;
    arm(options.startupTimeoutMs ?? DEFAULT_STARTUP_TIMEOUT_MS);
  }
  return { status: "starting", pid };
}

async function escalatePolishProcessExit(proc: ManagedPolishProcess, timeoutMs: number, options: EnsureSTTPolishServerOptions = {}): Promise<void> {
  const wait = async (): Promise<boolean> => {
    if (!proc.exited) {
      const deadline = Date.now() + timeoutMs;
      while (isPolishProcessAlive(proc.pid, options)) {
        const remaining = deadline - Date.now();
        if (remaining <= 0) return false;
        await Bun.sleep(Math.min(50, remaining));
      }
      return true;
    }
    return new Promise<boolean>((resolve) => {
      const timer = setTimeout(() => resolve(false), timeoutMs);
      void proc.exited!.then(() => { clearTimeout(timer); resolve(true); }, () => { clearTimeout(timer); resolve(false); });
    });
  };
  if (await wait()) return;
  if (!proc.exited && !isPolishProcessAlive(proc.pid, options)) return;
  try { proc.kill?.("SIGKILL"); } catch {}
  await wait();
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
