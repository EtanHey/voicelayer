/** Lazy private-pipe sidecar. VoiceBar -> MCP daemon -> this exact child.
 * No launchd owner, shared port, process adoption or startup-time model loading.
 */
import { existsSync } from "fs";
import { defaultParakeetModelPath, parakeetPython } from "./recognizer-assets";
import { migrateLegacyParakeetRuntime } from "./parakeet-runtime";
import { isAbsolute, join } from "path";
import { homedir } from "os";
import type { Subprocess } from "bun";
import { ModelResidency, modelIdleSeconds } from "./model-residency";
import { residencyBusy } from "./model-residency-busy";
import type { STTAttemptEvidence } from "./soundlayer/contracts";
import { isCurrentProcessLockOwner } from "./process-lock";
import { assertRecognizerNotDownloading, noteRecognizerEngine, confirmRecognizerCleanup, markRecognizerCleanupUnconfirmed } from "./recognizer-state";

export interface ParakeetResponse {
  text: string;
  complete: boolean;
  input_frames: number;
  covered_frames: number;
  sample_rate: number;
  last_token_end_s: number | null;
  inference_s: number;
  language: string | null;
  attemptEvidence?: STTAttemptEvidence;
  raw_token_times?: unknown[];
}

/** Preserve returned/partial provider bytes separately from the control error. */
export class ParakeetServiceError extends Error {
  cleanupFailure?: { name: string; message: string };
  constructor(readonly status: "ERROR" | "TIMEOUT" | "PARTIAL" | "INVALID", readonly attempt: unknown, message = "Parakeet provider failure") {
    super(message); this.name = "ParakeetServiceError";
  }
}

export interface ParakeetServerOptions {
  /** Tests may use an isolated protocol-only child; no model imports. */
  command?: string[] | (() => string[] | null);
  startupMs?: number;
  requestMs?: number;
  stopMs?: number;
  idleSeconds?: () => number;
  isBusy?: () => boolean;
  /** Daemon registration in production; explicit isolated owner in lab tools. */
  canLaunch?: () => boolean;
  onState?: (phase: "loading" | "ready" | "sleeping" | "error", error?: string) => void;
}

type Reply = Record<string, unknown>;
interface Child {
  proc: Subprocess<"pipe", "pipe", "pipe">;
  pending: Map<number, { resolve: (value: Reply) => void; reject: (error: Error) => void }>;
  stdout: Promise<void>;
  stderr: Promise<void>;
  partial: string;
  raw: Buffer;
  fault: ParakeetServiceError | null;
  stopping: boolean;
  unexpectedNotified: boolean;
}

/** Same multilingual v3 checkpoint as the measured SPEED lane. No download. */
export const DEFAULT_PARAKEET_CHECKPOINT = "mlx-community/parakeet-tdt-0.6b-v3";
export { defaultParakeetModelPath } from "./recognizer-assets";
export function parakeetCommand(env: NodeJS.ProcessEnv = process.env): string[] | null {
  const python = parakeetPython(env);
  const model = env.VOICELAYER_PARAKEET_MODEL || defaultParakeetModelPath(env);
  if (!python || !model || !isAbsolute(python) || !isAbsolute(model) || !existsSync(python) ||
      !["config.json", "model.safetensors", "tokenizer.model"].every(name => existsSync(join(model, name)))) return null;
  return [python, "-u", join(import.meta.dir, "parakeet-worker.py"), "--model", model, "--parent-pid", String(process.pid)];
}

export class ParakeetServer {
  private child: Child | null = null;
  private queue: Promise<unknown> = Promise.resolve();
  private sequence = 0;
  private closed = false;
  private readonly residency: ModelResidency;

  constructor(private readonly options: ParakeetServerOptions = {}) {
    this.residency = new ModelResidency(() => this.serial(async () => {
      try { await this.stopChild(); }
      catch (error) { this.notify("error", "cleanup-unconfirmed"); throw error; }
    }),
      options.idleSeconds ?? modelIdleSeconds, options.isBusy ?? residencyBusy);
  }

  isAvailable(): boolean {
    return !!(this.options.command ?? (this.options.canLaunch?.() ? parakeetCommand() : null));
  }

  /** Local owned handle only; no OS process inventory or foreign adoption. */
  get pid(): number | null { return this.child?.proc.exitCode === null ? this.child.proc.pid : null; }

  private serial<T>(work: () => Promise<T>): Promise<T> {
    const next = this.queue.then(work, work);
    this.queue = next.catch(() => {});
    return next;
  }

  private fail(child: Child, error: Error): void {
    for (const pending of child.pending.values()) pending.reject(error);
    child.pending.clear();
  }

  private notify(phase: "loading" | "ready" | "sleeping" | "error", reason?: string): void {
    try { this.options.onState?.(phase, reason); } catch { console.error("[voicelayer] Could not publish recognizer state"); }
  }

  private unexpected(child: Child, error: ParakeetServiceError): void {
    if (child.stopping || this.child !== child || child.unexpectedNotified) return;
    child.unexpectedNotified = true; child.fault ??= error;
    this.notify("error", "parakeet-process-or-channel-exited");
  }

  private async read(child: Child): Promise<void> {
    const decoder = new TextDecoder("utf-8", { fatal: true });
    let buffer = "";
    try {
      for await (const chunk of child.proc.stdout) {
        const remaining = 8 * 1024 * 1024 - child.raw.length;
        child.raw = Buffer.concat([child.raw, Buffer.from(chunk.subarray(0, remaining))]);
        if (chunk.length > remaining) throw new Error("Parakeet response exceeds 8MiB");
        buffer += decoder.decode(chunk, { stream: true });
        child.partial = buffer;
        if (Buffer.byteLength(buffer, "utf8") > 8 * 1024 * 1024) throw new Error("Parakeet response exceeds 8MiB");
        let newline: number;
        while ((newline = buffer.indexOf("\n")) >= 0) {
          const line = buffer.slice(0, newline); buffer = buffer.slice(newline + 1);
          child.partial = line;
          const value: unknown = JSON.parse(line);
          if (!value || typeof value !== "object" || !("id" in value) || typeof value.id !== "number") throw new Error("Parakeet protocol error");
          const pending = child.pending.get(value.id);
          if (!pending) throw new Error("Parakeet response identity mismatch");
          child.pending.delete(value.id);
          const reply = value as Reply;
          if (reply.ok !== true) pending.reject(new ParakeetServiceError(reply.status === "PARTIAL" ? "PARTIAL" : reply.status === "INVALID" ? "INVALID" : "ERROR", reply));
          else pending.resolve(reply);
          const rawNewline = child.raw.indexOf(10);
          child.raw = rawNewline < 0 ? Buffer.alloc(0) : child.raw.subarray(rawNewline + 1);
          child.partial = buffer;
        }
      }
      buffer += decoder.decode();
      if (buffer.length) throw new Error("Parakeet partial response");
      const error = new ParakeetServiceError("ERROR", { partial_stdout: child.partial, raw_stdout_base64: child.raw.toString("base64") }, "Parakeet channel closed");
      this.fail(child, error); this.unexpected(child, error);
    } catch (error) {
      child.fault = new ParakeetServiceError("INVALID", { partial_stdout: child.partial, raw_stdout_base64: child.raw.toString("base64") }, error instanceof Error ? error.message : "Parakeet channel error");
      this.fail(child, child.fault);
      this.unexpected(child, child.fault);
      // A malformed/unmatched response never leaves an untrusted child serving.
      try { child.proc.kill("SIGTERM"); } catch {}
    }
  }

  /** Cleanup remains a barrier, but may not erase the original provider bytes. */
  private async stopPreserving(error: unknown): Promise<void> {
    try { await this.stopChild(); }
    catch (cleanupError) {
      const cleanupFailure = { name: cleanupError instanceof Error ? cleanupError.name : "unknown", message: cleanupError instanceof Error ? cleanupError.message : "Owned cleanup failed" };
      if (error instanceof ParakeetServiceError) error.cleanupFailure = cleanupFailure;
      else if (error instanceof Error) { try { Object.defineProperty(error, "cleanupFailure", { value: cleanupFailure }); } catch {} }
      // stopChild keeps its owned handle until both exit and streams settle.
      // unload/replacement therefore still refuses while cleanup is unknown.
    }
  }

  private async command(child: Child, value: Reply, timeoutMs: number): Promise<Reply> {
    if (child.fault) throw child.fault;
    if (child.proc.exitCode !== null) throw new ParakeetServiceError("ERROR", { process_exit: child.proc.exitCode }, "Parakeet child already exited");
    const id = ++this.sequence;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const reply = new Promise<Reply>((resolve, reject) => {
      child.pending.set(id, { resolve, reject });
      timer = setTimeout(() => {
        child.pending.delete(id); reject(new ParakeetServiceError("TIMEOUT", { partial_stdout: child.partial, raw_stdout_base64: child.raw.toString("base64") }, "Parakeet request timeout"));
      }, timeoutMs);
    });
    // A stream error can arrive while flush is pending. Keep its original
    // rejection handled and let the same command deadline bound both phases.
    void reply.catch(() => {});
    try {
      child.proc.stdin.write(JSON.stringify({ ...value, id }) + "\n");
      await Promise.race([Promise.resolve(child.proc.stdin.flush()), reply.then(() => undefined)]);
      return await reply;
    } finally { child.pending.delete(id); clearTimeout(timer); }
  }

  private async ensure(): Promise<Child> {
    assertRecognizerNotDownloading("parakeet");
    if (this.closed) throw new Error("Parakeet owner is shut down");
    if (!this.options.command && !this.options.canLaunch?.()) throw new Error("Parakeet must be owned by the VoiceBar MCP daemon");
    if (this.child) {
      if (this.child.proc.exitCode === null && !this.child.fault) return this.child;
      await this.stopChild();
    }
    migrateLegacyParakeetRuntime();
    const configured = this.options.command;
    const command = typeof configured === "function" ? configured() : configured ?? parakeetCommand();
    if (!command) throw new Error("Configure local Parakeet Python and model paths");
    if (process.env.VOICELAYER_TEST_ISOLATED === "1" && !this.options.command) {
      throw new Error("Real Parakeet loading is disabled under the unit-test preload");
    }
    const proc = Bun.spawn(command, { stdin: "pipe", stdout: "pipe", stderr: "pipe", env: process.env });
    this.notify("loading");
    const child: Child = { proc, pending: new Map(), stdout: Promise.resolve(), stderr: Promise.resolve(), partial: "", raw: Buffer.alloc(0), fault: null, stopping: false, unexpectedNotified: false };
    this.child = child;
    child.stdout = this.read(child);
    // Always drain diagnostics, but do not echo potentially private provider text.
    child.stderr = (async () => { for await (const _chunk of proc.stderr) { /* drain */ } })().catch(() => {});
    void proc.exited.then(code => {
      const error = new ParakeetServiceError("ERROR", { process_exit: code, partial_stdout: child.partial }, "Parakeet child exited");
      this.fail(child, error); this.unexpected(child, error);
    });
    try {
      const health = await this.command(child, { op: "health" }, this.options.startupMs ?? 300_000);
      if (child.fault) throw child.fault;
      if (health.ready !== true || health.protocol !== 1 || health.pid !== proc.pid) throw new ParakeetServiceError("INVALID", health, "Parakeet health identity mismatch");
      this.notify("ready");
      return child;
    } catch (error) { await this.stopPreserving(error); this.notify("error", "parakeet-startup-failed"); throw error; }
  }

  async start(): Promise<void> {
    await this.residency.use(() => this.serial(async () => { await this.ensure(); }));
  }

  async health(): Promise<boolean> {
    // Monitoring must not keep an unused model loaded indefinitely. The serial
    // queue still orders this non-inference message against unload/inference.
    return this.serial(async () => {
      const child = this.child;
      if (!child || child.proc.exitCode !== null) return false;
      try {
        const reply = await this.command(child, { op: "health" }, this.options.requestMs ?? 5000);
        const healthy = reply.ready === true && reply.pid === child.proc.pid && reply.protocol === 1;
        if (!healthy) await this.stopChild();
        return healthy;
      } catch { await this.stopChild(); return false; }
    });
  }

  async transcribe(audioPath: string): Promise<ParakeetResponse> {
    return this.residency.use(() => this.serial(async () => {
      const child = await this.ensure();
      try {
        const result = await this.command(child, { op: "transcribe", audio_path: audioPath }, this.options.requestMs ?? 120_000);
        if (child.fault) throw child.fault;
        if (typeof result.text !== "string" || result.complete !== true || result.sample_rate !== 16000 ||
            !Number.isSafeInteger(result.input_frames) || (result.input_frames as number) <= 0 ||
            result.covered_frames !== result.input_frames || typeof result.inference_s !== "number" ||
            !Number.isFinite(result.inference_s) || result.inference_s < 0 ||
            (result.language !== null && typeof result.language !== "string") ||
            (result.last_token_end_s !== null && (typeof result.last_token_end_s !== "number" || !Number.isFinite(result.last_token_end_s) ||
              result.last_token_end_s < 0 || result.last_token_end_s > (result.input_frames as number) / 16000))) {
          throw new ParakeetServiceError(result.complete === false ? "PARTIAL" : "INVALID", result, "Parakeet incomplete response");
        }
        if (child.proc.exitCode !== null && child.proc.exitCode !== 0) throw new ParakeetServiceError("ERROR", result, "Parakeet child failed after response");
        return result as unknown as ParakeetResponse;
      } catch (error) { await this.stopPreserving(error); throw error; }
    }));
  }

  private async stopChild(): Promise<void> {
    const child = this.child;
    if (!child) return;
    child.stopping = true;
    this.fail(child, new Error("Parakeet stopped"));
    if (child.proc.exitCode === null) {
      try { child.proc.kill("SIGTERM"); } catch {}
      const wait = async () => {
        let timer: ReturnType<typeof setTimeout> | undefined;
        try { return await Promise.race([child.proc.exited.then(() => true), new Promise<false>(resolve => { timer = setTimeout(() => resolve(false), this.options.stopMs ?? 3000); })]); }
        finally { clearTimeout(timer); }
      };
      if (!await wait()) { child.proc.kill("SIGKILL"); if (!await wait()) throw new Error("Owned Parakeet child did not stop"); }
    }
    child.proc.stdin.end();
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      await Promise.race([
        Promise.all([child.proc.exited, child.stdout, child.stderr]),
        new Promise<never>((_, reject) => { timer = setTimeout(() => reject(new Error("Parakeet child streams did not close")), this.options.stopMs ?? 3000); }),
      ]);
    } finally { clearTimeout(timer); }
    if (this.child === child) this.child = null;
    this.residency.reset();
    this.notify("sleeping");
  }

  /** Restart is serialized after active requests and confirms owned exit first. */
  async restart(): Promise<void> {
    await this.residency.use(() => this.serial(async () => { await this.stopChild(); await this.ensure(); }));
  }

  /** Explicit language/failure fallback unloads P before asking Whisper to load. */
  async unload(): Promise<void> {
    try { await this.serial(() => this.stopChild()); }
    catch (error) { this.notify("error", "cleanup-unconfirmed"); throw error; }
  }

  /** Daemon shutdown: reject future use and stop only this instance's child. */
  async shutdown(): Promise<void> {
    this.closed = true;
    // Abort an active request rather than waiting its full inference deadline.
    if (this.child) { this.fail(this.child, new Error("Parakeet owner shut down")); try { this.child.proc.kill("SIGTERM"); } catch {} }
    await this.serial(() => this.stopChild());
    this.residency.reset();
  }

  killOnExit(): void {
    if (this.child && this.child.proc.exitCode === null) { try { this.child.proc.kill("SIGTERM"); } catch {} }
  }
}

let daemonParent: number | null = null;
const ownerShutdown = new AbortController();
export const parakeetOwnerShutdownSignal = ownerShutdown.signal;

/** Called only after mcp-server-daemon's parent and singleton-lock admission. */
export function registerParakeetDaemonOwner(): boolean {
  const expected = process.env.VOICEBAR_PARENT_PID;
  if (!expected || !/^[1-9][0-9]*$/.test(expected) || Number(expected) <= 1 || Number(expected) !== process.ppid || !isCurrentProcessLockOwner()) return false;
  daemonParent = Number(expected);
  return true;
}

export const parakeetServer = new ParakeetServer({ canLaunch: () => daemonParent !== null && process.ppid === daemonParent && isCurrentProcessLockOwner(),
  onState: (phase, error) => {
    if (phase === "sleeping") confirmRecognizerCleanup("parakeet");
    if (error === "cleanup-unconfirmed") markRecognizerCleanupUnconfirmed("parakeet");
    noteRecognizerEngine("parakeet", { phase, ...(phase === "ready" ? { available: true } : {}), error: error ?? null });
  } });
export async function shutdownParakeetEngines(): Promise<void> {
  // Also abort a one-shot Whisper fallback, before a failing P request can
  // dispatch another model during daemon shutdown.
  ownerShutdown.abort();
  await parakeetServer.shutdown();
}
process.on("exit", () => { ownerShutdown.abort(); parakeetServer.killOnExit(); });
