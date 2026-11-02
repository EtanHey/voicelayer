import { mkdirSync, mkdtempSync, renameSync, rmSync, statfsSync, createReadStream, openSync, writeSync, closeSync, existsSync, rmdirSync } from "fs";
import { dirname, join, isAbsolute } from "path";
import { createHash } from "crypto";
import { recognizerAssetPaths, defaultParakeetModelPath, readRecognizerAssets } from "./recognizer-assets";
import { RECOGNIZER_DOWNLOADS, type RecognizerDownloadFile } from "./recognizer-download-manifest";
import { provisionParakeetRuntime } from "./parakeet-runtime";
import { beginRecognizerMaintenance, finishRecognizerTransition, noteRecognizerEngine, readRecognizerStatus,
  recognizerOwnerSignal, recheckRecognizerBusy, type Recognizer } from "./recognizer-state";
export interface DownloadDeps {
  files(engine: Recognizer): RecognizerDownloadFile[];
  transfer(file: RecognizerDownloadFile, path: string, signal: AbortSignal, progress: (bytes: number) => void): Promise<void>;
  runtime(signal: AbortSignal): Promise<void>;
  freeBytes(path: string): number;
}
async function transfer(file: RecognizerDownloadFile, path: string, signal: AbortSignal, progress: (bytes: number) => void): Promise<void> {
  if (process.env.VOICELAYER_TEST_ISOLATED === "1") throw new Error("download-network-denied-in-tests");
  const response = await fetch(file.url, { signal });
  if (!response.ok || !response.body) throw new Error("download-http-failed");
  const fd = openSync(path, "wx", 0o600); let bytes = 0;
  try { for await (const chunk of response.body) {
    signal.throwIfAborted(); bytes += chunk.length; if (bytes > file.bytes) throw new Error("download-size-mismatch");
    let offset = 0; while (offset < chunk.length) offset += writeSync(fd, chunk, offset, chunk.length - offset);
    progress(chunk.length);
  } } finally { closeSync(fd); }
}
const defaults: DownloadDeps = { files: engine => RECOGNIZER_DOWNLOADS[engine], transfer, runtime: provisionParakeetRuntime,
  freeBytes: path => { const s = statfsSync(path); return s.bavail * s.bsize; } };
let active: { engine: Recognizer; controller: AbortController } | null = null;
export function cancelRecognizerDownload(engine: Recognizer): boolean {
  if (active?.engine !== engine) return false; active.controller.abort(); return true;
}
export async function downloadRecognizer(engine: Recognizer, deps: DownloadDeps = defaults) {
  let acquired = false, tmp: string | undefined, outcome: "accept" | "reject" = "accept", reason: string | undefined;
  const controller = new AbortController(), signal = AbortSignal.any([controller.signal, recognizerOwnerSignal]);
  const files = deps.files(engine), total = files.reduce((sum, f) => sum + f.bytes, 0); let received = 0, lastPublish = 0;
  const report = (state: "downloading" | "verifying" | "runtime" | "complete" | "cancelled" | "error", error: string | null = null) =>
    noteRecognizerEngine(engine, { download: { state, received_bytes: received, total_bytes: total, error } });
  try {
    beginRecognizerMaintenance(); acquired = true; active = { engine, controller };
    if (readRecognizerAssets(engine).assets_present) throw new Error("assets-already-present");
    if (readRecognizerStatus().engines[engine].phase !== "sleeping") throw new Error("recognizer-loaded");
    const destination = engine === "whisper" ? recognizerAssetPaths(engine)[0]! : process.env.VOICELAYER_PARAKEET_MODEL || defaultParakeetModelPath();
    if (!isAbsolute(destination)) throw new Error("invalid-model-path");
    const parent = dirname(destination); mkdirSync(parent, { recursive: true, mode: 0o700 });
    // Reserve model bytes + 3 GiB for the venv/wheels, on both destination filesystems.
    const reserve = engine === "parakeet" ? 3 * 1024 ** 3 : 256 * 1024 ** 2;
    if (deps.freeBytes(parent) < total + reserve) throw new Error("insufficient-disk-space");
    if (engine === "parakeet") {
      const { getStateDir } = await import("./paths"); const state = getStateDir(); mkdirSync(state, { recursive: true, mode: 0o700 });
      if (deps.freeBytes(state) < reserve) throw new Error("insufficient-disk-space");
    }
    tmp = mkdtempSync(join(parent, ".recognizer-download-")); report("downloading");
    for (const file of files) {
      const path = join(tmp, file.name);
      await deps.transfer(file, path, signal, bytes => { received += bytes; if (Date.now() - lastPublish > 200) { lastPublish = Date.now(); report("downloading"); } });
      signal.throwIfAborted(); report("verifying"); const hash = createHash("sha256"); let size = 0;
      for await (const chunk of createReadStream(path)) { signal.throwIfAborted(); size += chunk.length; hash.update(chunk); }
      if (size !== file.bytes || hash.digest("hex") !== file.sha256) throw new Error("download-checksum-mismatch");
    }
    if (engine === "parakeet") { report("runtime"); await deps.runtime(signal); }
    signal.throwIfAborted(); recheckRecognizerBusy();
    if (engine === "whisper") {
      if (existsSync(destination)) throw new Error("assets-exist-delete-first");
      renameSync(join(tmp, files[0]!.name), destination);
    } else {
      // Empty directories from a prior explicit delete are safe; never replace
      // a partial/external model tree or remove unrelated user files implicitly.
      if (existsSync(destination)) { try { rmdirSync(destination); } catch { throw new Error("assets-exist-delete-first"); } }
      renameSync(tmp, destination); tmp = undefined;
    }
    report("complete");
  } catch (error) {
    outcome = "reject"; reason = signal.aborted ? "download-cancelled" : error instanceof Error ? error.message : "download-failed";
    if (acquired) report(signal.aborted ? "cancelled" : "error", reason);
  } finally {
    if (tmp) rmSync(tmp, { recursive: true, force: true });
    if (acquired) { active = null; finishRecognizerTransition(); }
  }
  return { outcome, ...(reason ? { reason } : {}), recognizer_status: readRecognizerStatus() };
}
