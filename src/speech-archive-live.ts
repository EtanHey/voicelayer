import { speechArchiveWriter, type ArchiveWrite } from "./speech-archive-writer";
import { readFileSync, unlinkSync, readdirSync, lstatSync, openSync, closeSync, constants } from "fs";
import { join } from "path";
import type { SpeakArchiveContext } from "./speak-archive";
import { recoverSpeakArchive } from "./speak-archive-store";
import { recordingsArchiveRoot } from "./recordings-archive-fs";
import type { SpeechState } from "./speech-state";

const liveArchives = new Map<string, LiveSpeechArchive>();

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
    liveArchives.set(this.storedContext?.id ?? this.key, this);
    const work = this.tail.then(async () => {
      try {
        this.storedContext = (await speechArchiveWriter.write(this.key, operation, this.storedContext, this.root)).context;
        liveArchives.delete(this.key);
        liveArchives.set(this.storedContext.id, this);
        if (operation.kind === "audio") releaseAudio(operation);
      }
      catch {
        this.failures.push({ operation, code: "ARCHIVE_WRITE_FAILED" });
        console.error(`[speech] archive write failed: ${operation.kind}`);
      }
    });
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
    const failed = this.failures.splice(0);
    for (const { operation } of failed) this.enqueue(operation);
    await this.settled();
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
export async function flushSpeechArchives(): Promise<void> {
  for (const archive of liveArchives.values()) await archive.settled();
}
export function beginSpeechArchive(text: string, context?: SpeakArchiveContext): LiveSpeechArchive {
  if (context) { const current = liveArchives.get(context.id); if (current) return current; }
  const archive = new LiveSpeechArchive(context, text);
  liveArchives.set(archive.key, archive);
  return archive;
}
/** Only call after acquiring the daemon singleton; never recover another live writer. */
export function recoverSpeechArchives(): void {
  const root = recordingsArchiveRoot();
  let days: string[];
  try { days = readdirSync(root); } catch (e) {
    if (typeof e === "object" && e !== null && "code" in e && e.code === "ENOENT") return;
    throw e;
  }
  for (const day of days.filter(d => /^\d{4}-\d\d-\d\d$/.test(d))) {
    const dir = join(root, day);
    if (!lstatSync(dir).isDirectory() || lstatSync(dir).isSymbolicLink()) continue;
    for (const id of readdirSync(dir).filter(n => /^\d{4}-\d\d-\d\dT\d\d-\d\d-\d\d-\d{3}Z-[a-f0-9]{8}$/.test(n))) {
      try {
        const entry = lstatSync(join(dir, id));
        if (!entry.isDirectory() || entry.isSymbolicLink()) continue;
        const fd = openSync(join(dir, id, "metadata.json"), constants.O_RDONLY | constants.O_NOFOLLOW);
        let m: unknown;
        try { m = JSON.parse(readFileSync(fd, "utf8")); } finally { closeSync(fd); }
        if (typeof m !== "object" || m === null || !("source" in m) || m.source !== "speak") continue;
        const result = recoverSpeakArchive(id);
        if (result.kind === "failed") console.error(`[speech] recovery ${id}: ${result.code}`);
        else liveArchives.delete(id);
      } catch { console.error(`[speech] recovery unreadable: ${id}`); }
    }
  }
}

/** Once live speech owns an entry, ingress observers share its serialized writer. */
export function finishLiveSpeechReceipt(context: SpeakArchiveContext, status: "rejected" | "failed" | "stopped", reason: string | null): boolean {
  const archive = liveArchives.get(context.id);
  if (!archive) return false;
  archive.finish(status === "stopped" ? "stopped" : "failed", status === "rejected" ? "REJECTED" : reason ?? "USER_STOP");
  return true;
}
export function cancelLiveSpeech(): void {
  for (const archive of [...liveArchives.values()]) archive.finish("cancelled", "USER_CANCEL");
}
export function cancelQueuedSpeech(context: SpeakArchiveContext): void {
  beginSpeechArchive("", context).finish("cancelled", "QUEUE_CLEARED");
}
export function interruptLiveSpeech(): void {
  for (const archive of [...liveArchives.values()]) archive.move("interrupted", "PROCESS_EXIT");
}
