import { readFileSync, readdirSync, lstatSync, openSync, closeSync, constants } from "fs";
import { join } from "path";
import { createSpeakReceipt, type SpeakArchiveContext } from "./speak-archive";
import { readSpeakArchive, endSpeakPlayer, startSpeakPlayer, saveSpeakArtifact, saveSpeakGenerated, transitionSpeakArchive, recoverSpeakArchive } from "./speak-archive-store";
import { recordingsArchiveRoot } from "./recordings-archive-fs";
import type { SpeechState } from "./speech-state";

const liveArchives = new Map<string, LiveSpeechArchive>();

/** Explicit per-output identity, never an ambient current speech record. */
export class LiveSpeechArchive {
  private state: SpeechState = "requested";
  constructor(readonly context: SpeakArchiveContext) {
    const current = readSpeakArchive(context);
    if (current.kind === "failed") throw new Error(`Speech archive read: ${current.code}`);
    this.state = current.metadata.speech?.state ?? "requested";
    if (this.state === "requested") this.move("preparing");
  }
  playerStarted(): void {
    if (this.state !== "playing") this.move("playing");
    else {
      const result = startSpeakPlayer(this.context);
      if (result.kind === "failed") throw new Error(`Speech archive player: ${result.code}`);
    }
  }
  playerEnded(): void {
    const result = endSpeakPlayer(this.context);
    if (result.kind === "failed") throw new Error(`Speech archive player: ${result.code}`);
  }
  move(to: SpeechState, reason: string | null = null): void {
    // Chunk player starts share one output. Repeated observations are not transitions.
    if (this.state === to) return;
    const result = transitionSpeakArchive(this.context, to, reason);
    if (result.kind === "failed") throw new Error(`Speech archive transition: ${result.code}`);
    this.state = to;
    if (this.terminal) liveArchives.delete(this.context.id);
  }
  get terminal(): boolean { return ["completed", "stopped", "cancelled", "failed", "interrupted"].includes(this.state); }
  finish(to: "completed" | "stopped" | "cancelled" | "failed", reason: string): void {
    if (!this.terminal) this.move(to, reason);
  }
  generated(file: string, text: string, voice: string, profile: string, engine: string, index = 0, duration_ms: number | null = null): void {
    const audio_path = this.keepAudio(file, duration_ms);
    const saved = saveSpeakGenerated(this.context, { index, text, voice, profile, engine, audio_path, generated_at: new Date().toISOString() });
    if (saved.kind === "failed") throw new Error(`Speech archive generation: ${saved.code}`);
  }
  keepAudio(file: string, duration_ms: number | null = null): string {
    const result = saveSpeakArtifact(this.context, { bytes: readFileSync(file), role: "playback_ready", mime: "audio/mpeg",
      duration_ms, sample_rate: null, channels: null });
    if (result.kind === "failed") throw new Error(`Speech archive artifact: ${result.code}`);
    const audio_path = result.metadata.artifacts.at(-1)?.relative_path;
    if (!audio_path) throw new Error("Speech archive missing audio path");
    return audio_path;
  }
}
export function beginSpeechArchive(text: string, context?: SpeakArchiveContext): LiveSpeechArchive {
  if (!context) {
    const receipt = createSpeakReceipt({ input: text, request_id: crypto.randomUUID(), request_source: "direct", connection: null,
      format: null, blocking: null, requested: { mode: null, voice: null, profile: null, engine: null, rate: null },
      build: { app_version: null, daemon_version: null, git_sha: null, executable_hash: null } });
    if (receipt.kind === "failed") throw new Error(`Speech archive receipt: ${receipt.code}`);
    context = receipt.context;
  }
  const current = liveArchives.get(context.id);
  if (current) return current;
  const archive = new LiveSpeechArchive(context);
  liveArchives.set(context.id, archive);
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

export function cancelLiveSpeech(): void {
  for (const archive of [...liveArchives.values()]) archive.finish("cancelled", "USER_CANCEL");
}
export function cancelQueuedSpeech(context: SpeakArchiveContext): void {
  const archive = liveArchives.get(context.id);
  if (archive) archive.finish("cancelled", "QUEUE_CLEARED");
  else {
    const result = transitionSpeakArchive(context, "cancelled", "QUEUE_CLEARED");
    if (result.kind === "failed") console.error(`[speech] queued cancellation: ${result.code}`);
  }
}
export function interruptLiveSpeech(): void {
  for (const archive of [...liveArchives.values()]) archive.move("interrupted", "PROCESS_EXIT");
}
