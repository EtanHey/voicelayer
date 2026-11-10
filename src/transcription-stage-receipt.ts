import { createHash, randomUUID } from "crypto";
import { createReadStream, lstatSync, mkdirSync, realpathSync, statSync } from "fs";
import { basename, dirname, isAbsolute, join, relative } from "path";
import { atomicWriteFile, recordingsArchiveRoot } from "./recordings-archive-fs";

/** A sibling tree leaves immutable Ask archive directory identity unchanged. */
export function transcriptionStageReceiptDirectory(audioPath: string): string {
  const root = realpathSync(recordingsArchiveRoot());
  const local = relative(root, realpathSync(audioPath));
  if (!local || local.startsWith("..") || isAbsolute(local)) throw new Error("invalid archive boundary");
  return join(dirname(root), "transcription-stages", dirname(local));
}

/** Private archive sidecar, never an event payload or public diagnostic attachment. */
export async function beginTranscriptionStageReceipt(audioPath: string | undefined, raw: string, afterRules: string) {
  if (!audioPath) return undefined;
  try {
    const root = realpathSync(recordingsArchiveRoot());
    const audio = realpathSync(audioPath), local = relative(root, audio);
    if (!local || local.startsWith("..") || isAbsolute(local) || basename(audio) !== "audio.wav" ||
        lstatSync(audioPath).isSymbolicLink()) throw new Error("invalid archive boundary");
    const identity = statSync(audio), hash = createHash("sha256");
    for await (const bytes of createReadStream(audio)) hash.update(bytes);
    const current = statSync(audio);
    if (identity.ino !== current.ino || identity.size !== current.size || identity.mtimeMs !== current.mtimeMs) throw new Error("audio changed");
    const attemptID = randomUUID();
    const directory = transcriptionStageReceiptDirectory(audio);
    mkdirSync(directory, { recursive: true, mode: 0o700 });
    // Refuse a redirected private receipt tree; never follow a symlink to publish text.
    if (realpathSync(directory) !== directory) throw new Error("redirected receipt directory");
    const path = join(directory, `stt-stages-${attemptID}.json`);
    const receipt = {
      schema_version: 1, attempt_id: attemptID, created_at: new Date().toISOString(),
      audio_sha256: hash.digest("hex"), raw_stage: "backend-return", delivery_observed: false,
      complete: false, polish_status: null as string | null,
      stages: { raw, after_rules: afterRules, after_polish: null as string | null, delivered: null as string | null },
    };
    const save = () => atomicWriteFile(path, JSON.stringify(receipt) + "\n");
    save(); // Persist the attribution evidence BEFORE the model await.
    return (afterPolish: string, delivered: string, status: string | null) => {
      try {
        receipt.stages.after_polish = afterPolish;
        receipt.stages.delivered = delivered;
        receipt.polish_status = status;
        receipt.complete = true;
        save();
      } catch { console.error("[voicelayer] private STT stage receipt finalization failed"); }
    };
  } catch {
    // Do not leak transcript bytes or private paths through exception messages.
    console.error("[voicelayer] private STT stage receipt unavailable");
    return undefined;
  }
}
