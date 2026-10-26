import { migrateLegacySpeechSlice } from "./speech-archive-legacy-migration";
import { parentPort } from "node:worker_threads";
import { opendir, readFile } from "fs/promises";
import { join } from "path";
import { speechOpenIndex, unindexSpeech } from "./speech-open-index";
import { recordingsArchiveRoot } from "./recordings-archive-fs";
import { recoverSpeakArchive } from "./speak-archive-store";

// Steady-state recovery enumerates only open intents. Legacy migration runs in bounded worker slices.
parentPort?.on("message", async () => {
  const recovered: string[] = [];
  let visited = 0;
  const deadline = Date.now() + 4000;
  try {
    const dir = await opendir(speechOpenIndex());
    for await (const entry of dir) {
      if (++visited > 100 || Date.now() >= deadline) break;
      if (!entry.isFile() || !/^\d{4}-\d\d-\d\dT\d\d-\d\d-\d\d-\d{3}Z-[a-f0-9]{8}$/.test(entry.name)) continue;
      try {
        const pid = Number(await readFile(join(speechOpenIndex(), entry.name), "utf8"));
        if (Number.isInteger(pid) && pid > 0) {
          try { process.kill(pid, 0); continue; }
          catch (error) { if (!(error && typeof error === "object" && "code" in error && error.code === "ESRCH")) continue; }
        } else continue;
        // A crash may leave a stale marker after terminal publication. Never reconcile its audio.
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
        recovered.push(entry.name);
      } catch { console.error(`[speech] recovery unreadable: ${entry.name}`); }
    }
  } catch (error) {
    if (!(error && typeof error === "object" && "code" in error && error.code === "ENOENT")) console.error("[speech] open-index recovery failed");
  }
  let more = false;
  try {
    const migration = await migrateLegacySpeechSlice();
    recovered.push(...migration.recovered); more = migration.more;
  } catch (error) { console.error("[speech] legacy migration deferred", error); }
  parentPort!.postMessage({ recovered, more });
});
