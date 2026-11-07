/** Explicit model-file mutations. Capture and transcription mechanics stay unchanged. */
import { lstatSync, unlinkSync, existsSync } from "fs";
import { dirname } from "path";
import { resetBackendCache } from "./stt";
import { stopRecognizer } from "./recognizer-controller";
import { recognizerAssetPaths, readRecognizerAssets } from "./recognizer-assets";
import { assertRecognizerNotDownloading, beginRecognizerTransition, finishRecognizerTransition, readRecognizerStatus,
  noteRecognizerEngine, noteRecognizerEffective, persistRecognizer, setRecognizerRecovery, recheckRecognizerBusy, type Recognizer } from "./recognizer-state";

export async function deleteRecognizer(engine: Recognizer, stop: typeof stopRecognizer = stopRecognizer): Promise<{ outcome: "accept" | "reject"; reason?: string; recognizer_status: ReturnType<typeof readRecognizerStatus> }> {
  let acquired = false, outcome: "accept" | "reject" = "accept", reason: string | undefined;
  try {
    assertRecognizerNotDownloading(engine);
    beginRecognizerTransition(); acquired = true;
    const status = readRecognizerStatus(), other = engine === "parakeet" ? "whisper" : "parakeet";
    if (!readRecognizerAssets(other).assets_present) throw new Error("last-installed-recognizer");
    const paths = recognizerAssetPaths(engine);
    // Delete named regular files only. Never follow links into shared caches or
    // recurse through a user-supplied model directory containing unrelated data.
    // A symlinked model DIRECTORY makes each file lstat as a regular file, so
    // check the containing directory too: unlinking through it would delete the
    // files in the shared target (e.g. a Hugging Face cache).
    const assertManagedFiles = () => {
      for (const path of paths) {
        const dir = dirname(path);
        if (existsSync(dir) && lstatSync(dir).isSymbolicLink()) throw new Error("external-model-link");
        if (existsSync(path) && !lstatSync(path).isFile()) throw new Error("external-model-link");
      }
    };
    assertManagedFiles();
    // Keep transition ownership across the await: a request cannot load these
    // weights between confirmed process exit and the synchronous unlink.
    await stop(engine);
    recheckRecognizerBusy();
    assertManagedFiles();
    if (status.desired === engine) persistRecognizer(other);
    setRecognizerRecovery(null); resetBackendCache();
    if (status.effective === engine) noteRecognizerEffective(null);
    for (const path of paths) if (existsSync(path)) unlinkSync(path);
    noteRecognizerEngine(engine, { phase: "sleeping", available: null, error: null });
  } catch (error) {
    outcome = "reject"; reason = error instanceof Error ? error.message : "delete-failed";
  } finally { if (acquired) finishRecognizerTransition(); }
  return { outcome, ...(reason ? { reason } : {}), recognizer_status: readRecognizerStatus() };
}
