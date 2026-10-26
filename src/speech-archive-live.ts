import { speechArchiveWriter, type ArchiveWrite } from "./speech-archive-writer";
import { unlinkSync } from "fs";
import { Worker } from "node:worker_threads";
import type { SpeakArchiveContext } from "./speak-archive";
import type { SpeechState } from "./speech-state";

const liveArchives = new Map<string, LiveSpeechArchive>();
const deterministicWriteFailures = new Set(["CONFLICT", "FINALIZED", "INVALID_INPUT", "UNSAFE_PATH", "CORRUPT_METADATA"]);
const writeFailureCodes = new Set([...deterministicWriteFailures, "IO_ERROR", "WRITE_UNCERTAIN", "SYNC_UNCERTAIN", "ARCHIVE_WORKER_FAILED", "ARCHIVE_IO_FAILED"]);

const retainedAudio = new Map<string, Set<ArchiveWrite>>();
const cleanupRequested = new Set<string>();
/** Playback cleanup never removes a source until its durable copy succeeds. */
export function unlinkSpeechAudio(file: string): void {
  if (retainedAudio.get(file)?.size) { cleanupRequested.add(file); return; }
  unlinkSync(file);
}
function releaseAudio(operation: Extract<ArchiveWrite, { kind: "audio" }>): void {
  const holds = retainedAudio.get(operation.file);
  holds?.delete(operation);
  if (holds?.size) return;
  retainedAudio.delete(operation.file);
  if (cleanupRequested.delete(operation.file)) { try { unlinkSync(operation.file); } catch {} }
}
export class LiveSpeechArchive {
  private readonly root = process.env.QA_VOICE_RECORDINGS_DIR;
  private state: SpeechState = "preparing";
  private storedContext?: SpeakArchiveContext;
  private tail: Promise<void> = Promise.resolve();
  readonly failures: { operation: ArchiveWrite; code: string }[] = [];
  readonly key: string;
  constructor(context?: SpeakArchiveContext, text = "") {
    this.storedContext = context;
    this.key = context?.id ?? crypto.randomUUID();
    this.enqueue({ kind: "init", context, text });
  }
  get context(): SpeakArchiveContext {
    if (!this.storedContext) throw Error("Speech archive receipt is still pending; await settled()");
    return this.storedContext;
  }
  private enqueue(operation: ArchiveWrite): Promise<void> {
    return this.schedule(async () => {
      await this.retryWrites();
      await this.write(operation);
    });
  }
  private async write(operation: ArchiveWrite, retry = false): Promise<void> {
    try {
      this.storedContext = (await speechArchiveWriter.write(this.key, operation, this.storedContext, this.root)).context;
      liveArchives.delete(this.key);
      liveArchives.set(this.storedContext.id, this);
      if (operation.kind === "audio") releaseAudio(operation);
    } catch (error) {
      const code = error instanceof Error && writeFailureCodes.has(error.message) ? error.message : "ARCHIVE_WRITE_FAILED";
      if (retry && deterministicWriteFailures.has(code)) {
        console.error(`[speech] archive write dropped: ${operation.kind} ${code}`);
        return;
      }
      this.failures.push({ operation, code });
      console.error(`[speech] archive write failed: ${operation.kind}`);
    }
  }
  private async retryWrites(): Promise<void> {
    const failed = this.failures.splice(0);
    for (const { operation } of failed) await this.write(operation, true);
    // Audio/timing failures remain retryable, but cannot veto a later final status.
  }
  private schedule(run: () => Promise<void>): Promise<void> {
    liveArchives.set(this.storedContext?.id ?? this.key, this);
    const work = this.tail.then(run);
    this.tail = work;
    void work.then(() => {
      if (this.tail === work && this.terminal && !this.failures.length) {
        liveArchives.delete(this.key);
        if (this.storedContext) liveArchives.delete(this.storedContext.id);
      }
    });
    return work;
  }
  settled(): Promise<void> { return this.tail; }
  async retryFailed(): Promise<void> {
    await this.schedule(() => this.retryWrites());
  }
  playerStarted(): void {
    if (this.state !== "playing") this.move("playing");
    else this.enqueue({ kind: "start", at: new Date().toISOString() });
  }
  playerEnded(): void { this.enqueue({ kind: "end", at: new Date().toISOString() }); }
  move(to: SpeechState, reason: string | null = null): void {
    if (this.state === to || this.terminal) return;
    this.enqueue({ kind: "move", to, reason, at: new Date().toISOString() });
    this.state = to;
    // Keep this object until pending writes settle, including late generated audio.
  }
  get terminal(): boolean { return ["completed", "stopped", "cancelled", "failed", "interrupted"].includes(this.state); }
  finish(to: "completed" | "stopped" | "cancelled" | "failed", reason: string): void { this.move(to, reason); }
  generated(file: string, text: string, voice: string, profile: string, engine: string, index = 0, duration_ms: number | null = null): void {
    this.audio({ kind: "audio", file, duration_ms, generated: { text, voice, profile, engine, index, generated_at: new Date().toISOString() } });
  }
  keepAudio(file: string, duration_ms: number | null = null): void { this.audio({ kind: "audio", file, duration_ms }); }
  private audio(operation: Extract<ArchiveWrite, { kind: "audio" }>): void {
    const holds = retainedAudio.get(operation.file) ?? new Set<ArchiveWrite>();
    retainedAudio.set(operation.file, holds);
    holds.add(operation);
    this.enqueue(operation);
  }
}
export async function flushSpeechArchives(context?: SpeakArchiveContext): Promise<void> {
  const archives = context ? [liveArchives.get(context.id)].filter((archive): archive is LiveSpeechArchive => archive !== undefined) : [...new Set(liveArchives.values())];
  for (const archive of archives) { await archive.settled(); await archive.retryFailed(); }
}
export function beginSpeechArchive(text: string, context?: SpeakArchiveContext): LiveSpeechArchive {
  if (context) { const current = liveArchives.get(context.id); if (current) return current; }
  const archive = new LiveSpeechArchive(context, text);
  liveArchives.set(archive.key, archive);
  return archive;
}
/** Only call after acquiring the daemon singleton; never recover another live writer. */
export function recoverSpeechArchives(): Promise<void> {
  return new Promise(resolve => {
    const worker = new Worker(new URL("./speech-archive-recovery-worker.ts", import.meta.url), { env: process.env });
    const finish = () => { clearTimeout(timeout); void worker.terminate(); resolve(); };
    let timeout = setTimeout(() => { console.error("[speech] recovery budget exhausted; remaining intents retained"); finish(); }, 5000);
    worker.on("message", ({ recovered, more }: { recovered: string[]; more: boolean }) => {
      for (const id of recovered) liveArchives.delete(id);
      if (!more) { finish(); return; }
      clearTimeout(timeout);
      timeout = setTimeout(() => { console.error("[speech] recovery budget exhausted; migration checkpoint retained"); finish(); }, 5000);
      worker.postMessage({});
    });
    worker.once("error", () => { console.error("[speech] recovery worker failed"); finish(); });
    worker.once("exit", finish);
    worker.postMessage({});
  });
}

/** Once live speech owns an entry, ingress observers share its serialized writer. */
export function finishLiveSpeechReceipt(context: SpeakArchiveContext, status: "rejected" | "failed" | "stopped", reason: string | null): boolean {
  const archive = liveArchives.get(context.id);
  if (!archive) return false;
  archive.finish(status === "stopped" ? "stopped" : "failed", status === "rejected" ? "REJECTED" : reason ?? "USER_STOP");
  return true;
}
export function cancelQueuedSpeech(context: SpeakArchiveContext): void {
  beginSpeechArchive("", context).finish("cancelled", "QUEUE_CLEARED");
}
export function interruptLiveSpeech(): void {
  for (const archive of [...liveArchives.values()]) archive.move("interrupted", "PROCESS_EXIT");
}
