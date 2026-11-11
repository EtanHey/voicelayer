import { createHash, randomUUID } from "crypto";
import { createReadStream, lstatSync, mkdirSync, readFileSync, readdirSync, realpathSync, statSync, unlinkSync } from "fs";
import { basename, dirname, isAbsolute, join, relative } from "path";
import { atomicWriteFile, recordingsArchiveRoot } from "./recordings-archive-fs";

export const STAGE_RECEIPT_RETENTION = { perTake: 5, total: 500, days: 30 } as const;

/** Prune diagnostics only: never descend into aliases or the recordings tree. */
export function pruneTranscriptionStageReceipts(store: string, now = Date.now()): void {
  const privateDirectory = (path: string) => {
    const s = lstatSync(path);
    return s.isDirectory() && !s.isSymbolicLink() && s.uid === process.getuid?.() && (s.mode & 0o777) === 0o700;
  };
  try {
    if (!privateDirectory(store) || realpathSync(store) !== store) return;
    const entries: Array<{ path: string; take: string; created: number; ino: number; dev: number }> = [];
    for (const day of readdirSync(store)) {
      if (!/^\d{4}-\d{2}-\d{2}$/u.test(day)) continue;
      const dayPath = join(store, day);
      if (!privateDirectory(dayPath)) continue;
      for (const take of readdirSync(dayPath)) {
        if (!/^\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-\d{3}Z-[a-f0-9]{8}$/u.test(take) || !take.startsWith(day)) continue;
        const directory = join(dayPath, take);
        if (!privateDirectory(directory)) continue;
        for (const name of readdirSync(directory)) {
          if (!/^stt-stages-[a-f0-9-]{36}\.json$/u.test(name)) continue;
          const path = join(directory, name), s = lstatSync(path);
          if (!s.isFile() || s.isSymbolicLink() || s.nlink !== 1 || s.uid !== process.getuid?.() || (s.mode & 0o777) !== 0o600) continue;
          let receipt;
          try { receipt = JSON.parse(readFileSync(path, "utf8")); } catch { continue; }
          const created = Date.parse(receipt.created_at);
          if (receipt.schema_version !== 1 || name !== `stt-stages-${receipt.attempt_id}.json` || !Number.isFinite(created)) continue;
          entries.push({ path, take, created, ino: s.ino, dev: s.dev });
        }
      }
    }
    const newest = [...entries].sort((a, b) => b.created - a.created || b.path.localeCompare(a.path));
    const kept = new Set<string>(), perTake = new Map<string, number>();
    for (const entry of newest) {
      const count = perTake.get(entry.take) ?? 0;
      if (entry.created < now - STAGE_RECEIPT_RETENTION.days * 86400000 ||
          kept.size >= STAGE_RECEIPT_RETENTION.total || count >= STAGE_RECEIPT_RETENTION.perTake) continue;
      kept.add(entry.path); perTake.set(entry.take, count + 1);
    }
    // Oldest first, with identity and alias checks repeated immediately before unlink.
    for (const entry of newest.reverse()) {
      if (kept.has(entry.path) || realpathSync(dirname(entry.path)) !== dirname(entry.path)) continue;
      const current = lstatSync(entry.path);
      if (current.isFile() && !current.isSymbolicLink() && current.nlink === 1 && current.uid === process.getuid?.() &&
          (current.mode & 0o777) === 0o600 && current.ino === entry.ino && current.dev === entry.dev) unlinkSync(entry.path);
    }
  } catch { console.error("[voicelayer] private STT stage receipt retention unavailable"); }
}

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
    const save = () => {
      atomicWriteFile(path, JSON.stringify(receipt) + "\n");
      pruneTranscriptionStageReceipts(join(dirname(root), "transcription-stages"));
    };
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
