import { access, readFile, readdir } from "fs/promises";
import { join } from "path";
import { atomicWriteFile, recordingsArchiveRoot } from "./recordings-archive-fs";
import { speechOpenIndex } from "./speech-open-index";
import { recoverSpeakArchive } from "./speak-archive-store";

const terminal = new Set(["completed", "stopped", "replaced", "rejected", "failed", "interrupted_unknown"]);
const absent = (error: unknown) => error && typeof error === "object" && "code" in error && error.code === "ENOENT";

/** Worker-only upgrade pass. Checkpoint each bounded slice; a restart resumes it.
 * Indexed records retain their owner checks in the normal recovery path.
 */
export async function migrateLegacySpeechSlice(): Promise<{ more: boolean; recovered: string[] }> {
  const root = recordingsArchiveRoot();
  const checkpoint = join(root, ".speech-index-migration-v1");
  let cursor = "";
  try { cursor = await readFile(checkpoint, "utf8"); }
  catch (error) { if (!absent(error)) throw error; }
  if (cursor === "done") return { more: false, recovered: [] };
  const recovered: string[] = [];
  let visited = 0;
  const deadline = Date.now() + 3000;
  let days: string[];
  try { days = (await readdir(root, { withFileTypes: true })).filter(day => day.isDirectory() && /^\d{4}-\d\d-\d\d$/.test(day.name)).map(day => day.name).sort(); }
  catch (error) { if (absent(error)) return { more: false, recovered }; throw error; }
  for (const day of days) {
    if (day < cursor.slice(0, 10)) continue;
    const entries = await readdir(join(root, day), { withFileTypes: true });
    entries.sort((a, b) => a.name.localeCompare(b.name));
    for (const entry of entries) {
      const id = entry.name;
      if (!entry.isDirectory() || !/^\d{4}-\d\d-\d\dT\d\d-\d\d-\d\d-\d{3}Z-[a-f0-9]{8}$/.test(id) || id.slice(0, 10) !== day || id <= cursor) continue;
      // Never inspect audio for terminal history, nor recover an indexed live owner.
      let indexed = true;
      try { await access(join(speechOpenIndex(), id)); }
      catch (error) { if (!absent(error)) throw error; indexed = false; }
      if (!indexed) {
        try {
          const metadata = JSON.parse(await readFile(join(root, day, id, "metadata.json"), "utf8"));
          if (metadata.source === "speak" && !terminal.has(metadata.status)) {
            const result = recoverSpeakArchive(id);
            if (result.kind === "failed") throw new Error(`legacy speech recovery ${id}: ${result.code}`);
            recovered.push(id);
          }
        } catch (error) { if (!absent(error)) throw error; }
      }
      cursor = id;
      if (++visited >= 100 || Date.now() >= deadline) {
        atomicWriteFile(checkpoint, cursor);
        return { more: true, recovered };
      }
    }
  }
  atomicWriteFile(checkpoint, "done");
  return { more: false, recovered };
}
