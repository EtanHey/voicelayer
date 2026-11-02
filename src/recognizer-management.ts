/** Explicit model-file mutations. Capture and transcription mechanics stay unchanged. */
import { lstatSync, unlinkSync, existsSync } from "fs";
import { resetBackendCache } from "./stt";
import { parakeetServer } from "./parakeet-server";
import { whisperHasResidentHandle } from "./whisper-server";
import { recognizerAssetPaths, readRecognizerAssets } from "./recognizer-assets";
import { beginRecognizerTransition, finishRecognizerTransition, readRecognizerStatus,
  noteRecognizerEngine, noteRecognizerEffective, persistRecognizer, setRecognizerRecovery, type Recognizer } from "./recognizer-state";

export function deleteRecognizer(engine: Recognizer): { outcome: "accept" | "reject"; reason?: string; recognizer_status: ReturnType<typeof readRecognizerStatus> } {
  let acquired = false, outcome: "accept" | "reject" = "accept", reason: string | undefined;
  try {
    beginRecognizerTransition(); acquired = true;
    const status = readRecognizerStatus(), other = engine === "parakeet" ? "whisper" : "parakeet";
    if (status.engines[engine].phase !== "sleeping" || (engine === "parakeet" ? parakeetServer.pid !== null : whisperHasResidentHandle())) throw new Error("recognizer-loaded");
    if (!readRecognizerAssets(other).assets_present) throw new Error("last-installed-recognizer");
    const paths = recognizerAssetPaths(engine);
    // Delete named regular files only. Never follow links into shared caches or
    // recurse through a user-supplied model directory containing unrelated data.
    for (const path of paths) if (existsSync(path) && !lstatSync(path).isFile()) throw new Error("external-model-link");
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
