import { resolveBinary } from "./resolve-binary";
import { parentPort } from "node:worker_threads";
import { readFileSync, openSync, closeSync, fsyncSync, constants } from "fs";
import { createSpeakReceipt, type SpeakArchiveContext } from "./speak-archive";
import { readSpeakArchive, transitionSpeakArchive, startSpeakPlayer, endSpeakPlayer, saveSpeakArtifact, saveSpeakGenerated } from "./speak-archive-store";
import type { ArchiveWrite } from "./speech-archive-writer";
const contexts = new Map<string, SpeakArchiveContext>();
function stored<T extends { kind: string }>(result: T): Extract<T, { kind: "stored" }> {
  if (result.kind !== "stored") throw Error("code" in result ? String(result.code) : "ARCHIVE_FAILED");
  return result as Extract<T, { kind: "stored" }>;
}
function audioDuration(file: string): number | null {
  const probe = resolveBinary("ffprobe");
  if (!probe) return null;
  const result = Bun.spawnSync([probe, "-v", "error", "-show_entries", "format=duration", "-of", "default=noprint_wrappers=1:nokey=1", file],
    { env: process.env, stdout: "pipe", stderr: "ignore", timeout: 3000 });
  const seconds = Number(result.stdout.toString().trim());
  return result.exitCode === 0 && Number.isFinite(seconds) && seconds > 0 ? seconds * 1000 : null;
}
function execute(key: string, operation: ArchiveWrite, hint?: SpeakArchiveContext): SpeakArchiveContext {
  let context = hint ?? contexts.get(key);
  if (operation.kind === "init") {
    context = operation.context ?? context;
    if (!context) {
      const receipt = createSpeakReceipt({ input: operation.text, request_id: key, request_source: "direct", connection: null,
        format: null, blocking: null, requested: { mode: null, voice: null, profile: null, engine: null, rate: null },
        build: { app_version: null, daemon_version: null, git_sha: null, executable_hash: null } });
      if (receipt.kind !== "created") throw Error(receipt.code);
      context = receipt.context;
    }
    contexts.set(key, context);
    const current = stored(readSpeakArchive(context));
    if (!current.metadata.speech || current.metadata.speech.state === "requested") stored(transitionSpeakArchive(context, "preparing"));
  } else {
    if (!context) throw Error("ARCHIVE_NOT_INITIALIZED");
    if (operation.kind === "move") {
      // A failed directory fsync may have published the complete transition already.
      const current = stored(readSpeakArchive(context));
      if (current.metadata.speech?.state !== operation.to || current.metadata.speech.reason !== operation.reason)
        stored(transitionSpeakArchive(context, operation.to, operation.reason, operation.at));
    } else if (operation.kind === "start") stored(startSpeakPlayer(context, operation.at));
    else if (operation.kind === "end") stored(endSpeakPlayer(context, operation.at));
    else if (operation.kind === "audio") {
      const result = stored(saveSpeakArtifact(context, { bytes: readFileSync(operation.file), role: "playback_ready", mime: "audio/mpeg",
        duration_ms: operation.duration_ms ?? audioDuration(operation.file), sample_rate: null, channels: null }));
      const audio_path = result.metadata.artifacts.at(-1)?.relative_path;
      if (!audio_path) throw Error("ARCHIVE_AUDIO_MISSING");
      if (operation.generated) stored(saveSpeakGenerated(context, { ...operation.generated, audio_path }));
    }
  }
  // Also settle post-rename uncertainty when a retry observes the intended state already present.
  const fd = openSync(context.path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_DIRECTORY);
  try { fsyncSync(fd); } finally { closeSync(fd); }
  return context;
}
export function applyArchiveWrite(key: string, operation: ArchiveWrite, context?: SpeakArchiveContext): { context: SpeakArchiveContext } | { error: string } {
  let error = "ARCHIVE_FAILED";
  for (let attempt = 0; attempt < 3; attempt++) {
    try { const result = execute(key, operation, context); contexts.delete(key); return { context: result }; }
    catch (e) { error = e instanceof Error && /^[A-Z_]+$/.test(e.message) ? e.message : "ARCHIVE_IO_FAILED"; }
  }
  return { error };
}
parentPort?.on("message", (message: { id: number; key: string; operation: ArchiveWrite; root?: string; context?: SpeakArchiveContext }) => {
  const { id, key, operation, root, context } = message;
  if (root !== undefined) process.env.QA_VOICE_RECORDINGS_DIR = root;
  const result = applyArchiveWrite(key, operation, context);
  parentPort!.postMessage("error" in result ? { id, error: result.error } : { id, reply: result });
});
