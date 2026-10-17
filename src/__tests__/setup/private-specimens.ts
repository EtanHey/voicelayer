import { homedir } from "os";
import { join, resolve } from "path";

/** Overrides select a source; only this exact flag authorizes private access. */
export function privateCorpusEnabled(env: NodeJS.ProcessEnv = process.env): boolean {
  return env.VOICELAYER_TEST_REAL_ARCHIVE === "1";
}

/** Read-only paths only. No HOME resolution or filesystem probes before opt-in. */
export function privateCorpusPaths(suite: string, env: NodeJS.ProcessEnv = process.env) {
  if (!privateCorpusEnabled(env)) {
    console.error(`[${suite}] SKIPPING private corpus: set VOICELAYER_TEST_REAL_ARCHIVE=1 (read-only).`);
    return null;
  }
  const home = env.HOME || homedir();
  const local = join(home, "Gits/voicelayer/docs.local");
  const explicit = env.VOICELAYER_TEST_SPECIMEN_DIR?.trim();
  const recordings = explicit ? resolve(explicit) : join(home, ".local/share/voicelayer/recordings");
  return {
    recordings,
    correctionTsv: explicit ? join(recordings, "correction-corpus.tsv")
      : join(local, "recon-2026-09-06/correction-corpus.tsv"),
    numbersManifest: env.VOICELAYER_NUMBERS_CORPUS_PATH
      ?? join(local, "va-numbers/bakeoff-corpus.private.json"),
    prosePairs: join(local, "recon-2026-09-06/pairs.json"),
    proseGold: join(local, "recon-2026-09-05/gold"),
    polishShadow: env.QA_VOICE_STT_POLISH_LOG_PATH
      ?? join(home, ".voicelayer/eval/polish-shadow.jsonl"),
  };
}
