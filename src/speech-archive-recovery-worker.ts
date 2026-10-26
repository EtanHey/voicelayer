import { migrateLegacySpeechSlice } from "./speech-archive-legacy-migration";
import { parentPort } from "node:worker_threads";
import { opendir, readFile } from "fs/promises";
import { join } from "path";
import { speechOpenIndex, speechPendingIndex, finishSpeechReceipt, unindexSpeech } from "./speech-open-index";
import { recordingsArchiveRoot } from "./recordings-archive-fs";
import { recoverSpeakArchive } from "./speak-archive-store";
import { preparePrivateSpeechDirectory } from "./speech-archive-directory";

// Keep the directory cursor across bounded messages, including when the first
// hundred intents belong to live writers. Never scan terminal archive history here.
async function* intents() {
  for (const pending of [true, false]) {
    const path = pending ? speechPendingIndex() : speechOpenIndex();
    preparePrivateSpeechDirectory(path);
    const dir = await opendir(path);
    for await (const entry of dir) yield { entry, path, pending };
  }
}
const cursor = intents();
let indexDone = false;
parentPort?.on("message", async () => {
  const recovered: string[] = [];
  const deadline = Date.now() + 4000;
  let more = false;
  try {
    for (let visited = 0; !indexDone && visited < 100 && Date.now() < deadline; visited++) {
      const next = await cursor.next();
      if (next.done) { indexDone = true; break; }
      const { entry, path, pending } = next.value;
      if (!(pending ? entry.isDirectory() : entry.isFile()) || !/^\d{4}-\d\d-\d\dT\d\d-\d\d-\d\d-\d{3}Z-[a-f0-9]{8}$/.test(entry.name)) continue;
      try {
        let pid: number;
        if (pending) {
          const receipt = join(path, entry.name);
          preparePrivateSpeechDirectory(receipt);
          const owners = await opendir(receipt);
          let owner: string | undefined;
          for await (const candidate of owners) {
            if (owner !== undefined || !candidate.isDirectory() || !/^[1-9]\d*$/.test(candidate.name)) { owner = undefined; break; }
            owner = candidate.name;
          }
          pid = Number(owner);
        } else pid = Number(await readFile(join(path, entry.name), "utf8"));
        if (!Number.isSafeInteger(pid) || pid <= 0) continue;
        try { process.kill(pid, 0); continue; }
        catch (error) { if (!(error && typeof error === "object" && "code" in error && error.code === "ESRCH")) continue; }
        // A crash may leave a stale intent after terminal publication. Never reconcile its audio.
        let terminal = false;
        try {
          const metadata = JSON.parse(await readFile(join(recordingsArchiveRoot(), entry.name.slice(0, 10), entry.name, "metadata.json"), "utf8"));
          terminal = ["completed", "stopped", "replaced", "rejected", "failed", "interrupted_unknown"].includes(metadata.status);
        } catch (error) {
          if (!(error && typeof error === "object" && "code" in error && error.code === "ENOENT")) throw error;
        }
        if (terminal) unindexSpeech(entry.name);
        else {
          const result = recoverSpeakArchive(entry.name);
          if (result.kind === "failed") { console.error(`[speech] recovery ${entry.name}: ${result.code}`); continue; }
        }
        if (pending) finishSpeechReceipt(entry.name, pid);
        recovered.push(entry.name);
      } catch { console.error(`[speech] recovery unreadable: ${entry.name}`); }
    }
    more = !indexDone;
  } catch { console.error("[speech] open-index recovery failed"); indexDone = true; }
  try {
    const migration = await migrateLegacySpeechSlice();
    recovered.push(...migration.recovered); more = more || migration.more;
  } catch (error) { console.error("[speech] legacy migration deferred", error); }
  parentPort!.postMessage({ recovered, more });
});
