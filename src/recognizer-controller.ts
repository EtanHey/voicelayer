import { getRecordingState } from "./input";
import { residencyBusy } from "./model-residency-busy";
import { parakeetServer } from "./parakeet-server";
import { migrateLegacyParakeetRuntime } from "./parakeet-runtime";
import { ensureServer, unloadOwnedServer, whisperServerLaunchRecord, probeWhisperServerListeners, onWhisperModelStateChange } from "./whisper-server";
import { resetBackendCache } from "./stt";
import { whisperLifecycleGate } from "./whisper-lifecycle-gate";
import { mkdirSync } from "fs";
import { join } from "path";
import { randomUUID } from "crypto";
import { getStateDir, safeWriteFileSync } from "./paths";
import { assertRecognizerNotDownloading, beginRecognizerTransition, beginRecognizerMaintenance, finishRecognizerTransition, configureRecognizerBusyProbe, noteRecognizerEffective,
  noteRecognizerEngine, persistRecognizer, readRecognizerStatus, recheckRecognizerBusy, setRecognizerRecovery,
  confirmRecognizerCleanup, markRecognizerCleanupUnconfirmed, assertRecognizerOwnerOpen, recognizerOwnerClosed, type Recognizer, type RecognizerStatus } from "./recognizer-state";
configureRecognizerBusyProbe(() => getRecordingState() === "recording" ? "capture-active" : residencyBusy() ? "voice-busy" : whisperLifecycleGate.isInUse || whisperLifecycleGate.isUnloading ? "transition-active" : null);
onWhisperModelStateChange((event) => {
  const record = whisperServerLaunchRecord();
  if (event?.reason === "unexpected-exit") {
    noteRecognizerEngine("whisper", { phase: "error", available: false, error: "whisper-unexpected-exit" });
    return;
  }
  noteRecognizerEngine("whisper", { phase: record ? "ready" : "sleeping", ...(record ? { available: true, error: null } : {}) });
});
export interface RecognizerTransitionDeps {
  assetsPresent?(engine: Recognizer): boolean;
  stopP(): Promise<unknown>; stopW(): Promise<unknown>; startP(): Promise<unknown>; startW(): Promise<unknown>; reset(): void;
}
const defaults: RecognizerTransitionDeps = {
  stopP: () => parakeetServer.unload(),
  stopW: async () => {
    if (!whisperServerLaunchRecord()) {
      const port = Number.parseInt(process.env.QA_VOICE_WHISPER_SERVER_PORT ?? "", 10) || 8178;
      const listeners = probeWhisperServerListeners(port);
      if (listeners?.length === 0) return;
      throw new Error("cleanup-unconfirmed");
    }
    const result = await unloadOwnedServer(residencyBusy); if (result.outcome !== "accept") throw new Error("cleanup-unconfirmed");
  },
  startP: () => parakeetServer.start(), startW: () => ensureServer(), reset: resetBackendCache,
};
const activeSelections = new Set<Promise<unknown>>();
export async function joinRecognizerSelections(): Promise<void> { await Promise.allSettled([...activeSelections]); }
export function selectRecognizer(value: Recognizer, deps: RecognizerTransitionDeps = defaults): ReturnType<typeof selectRecognizerOwned> {
  const selected = selectRecognizerOwned(value, deps);
  activeSelections.add(selected);
  void selected.then(() => activeSelections.delete(selected), () => activeSelections.delete(selected));
  return selected;
}
async function selectRecognizerOwned(value: Recognizer, deps: RecognizerTransitionDeps = defaults): Promise<{ outcome: "accept" | "reject"; reason?: string; recognizer_status: RecognizerStatus }> {
  if (value !== "parakeet" && value !== "whisper") return { outcome: "reject", reason: "invalid-recognizer", recognizer_status: readRecognizerStatus() };
  const previous = readRecognizerStatus();
  try { assertRecognizerNotDownloading(value); beginRecognizerTransition(); }
  catch (error) { return { outcome: "reject", reason: error instanceof Error ? error.message : "voice-busy", recognizer_status: readRecognizerStatus() }; }
  let outcome: "accept" | "reject" = "accept", reason: string | undefined;
  let preferenceChanged = false;
  const stop = async (engine: Recognizer) => {
    try {
      await (engine === "parakeet" ? deps.stopP() : deps.stopW());
      confirmRecognizerCleanup(engine);
      noteRecognizerEngine(engine, { phase: "sleeping" });
    } catch { markRecognizerCleanupUnconfirmed(engine); throw new Error("cleanup-unconfirmed"); }
  };
  const start = (engine: Recognizer) => {
    assertRecognizerOwnerOpen();
    assertRecognizerNotDownloading(engine);
    return engine === "parakeet" ? deps.startP() : deps.startW();
  };
  try {
    if (value === "parakeet" && deps === defaults && parakeetServer.pid === null) migrateLegacyParakeetRuntime();
    if (!(deps.assetsPresent?.(value) ?? readRecognizerStatus().engines[value].assets_present)) throw new Error("assets-not-present");
    // Never mutate preference or load a successor until both prior owners have
    // accepted cleanup. A foreign/adopted Whisper is not ours to signal.
    await stop("parakeet");
    recheckRecognizerBusy();
    await stop("whisper");
    recheckRecognizerBusy();
    try { persistRecognizer(value); preferenceChanged = true; } catch { throw new Error("settings-write-failed"); }
    setRecognizerRecovery(null); noteRecognizerEffective(null);
    noteRecognizerEngine(value, { phase: "loading", error: null });
    try {
      await start(value);
      assertRecognizerOwnerOpen();
      noteRecognizerEngine(value, { phase: "ready", available: true, error: null }); noteRecognizerEffective(value);
    } catch (startupError) {
      if (recognizerOwnerClosed()) { await stop(value); throw new Error("owner-shutdown"); }
      const failureReason = value + "-startup-failed";
      const attempt = startupError instanceof Error ? { name: startupError.name, message: startupError.message,
        ...("attempt" in startupError ? { attempt: startupError.attempt } : {}) } : { name: "unknown" };
      let evidencePath: string | undefined;
      try {
        const directory = join(getStateDir(), "recognizer-switch-errors"); mkdirSync(directory, { recursive: true, mode: 0o700 });
        evidencePath = join(directory, randomUUID() + ".json");
        safeWriteFileSync(evidencePath, JSON.stringify({ requested: value, previousDesired: previous.desired,
          previousEffective: previous.effective, reason: failureReason, attempt }) + "\n");
      } catch { evidencePath = undefined; console.error("[voicelayer] Could not save recognizer load failure; provider error remains in state"); }
      // A failed launch can still own a process. Confirm its cleanup before
      // restoring the previous choice, symmetrically for either engine.
      await stop(value);
      assertRecognizerOwnerOpen();
      noteRecognizerEngine(value, { phase: "error", available: false, error: failureReason });
      noteRecognizerEffective(null, failureReason);
      const restore = previous.effective ?? previous.desired;
      if (restore !== value) {
        recheckRecognizerBusy(); noteRecognizerEngine(restore, { phase: "loading", error: null });
        try {
          await start(restore);
          assertRecognizerOwnerOpen();
          setRecognizerRecovery({ engine: restore, failed: value, attempt, evidencePath });
          noteRecognizerEngine(restore, { phase: "ready", available: true, error: null }); noteRecognizerEffective(restore, failureReason);
        } catch {
          await stop(restore);
          assertRecognizerOwnerOpen();
          noteRecognizerEngine(restore, { phase: "error", available: false, error: restore + "-startup-failed" });
          noteRecognizerEffective(null, failureReason);
        }
      }
    }
  } catch (error) {
    reason = error instanceof Error ? error.message : "cleanup-unconfirmed"; outcome = "reject";
    noteRecognizerEngine(value, { phase: "error", error: reason });
  } finally { try { if (preferenceChanged) deps.reset(); } finally { finishRecognizerTransition(); } }
  return { outcome, ...(reason ? { reason } : {}), recognizer_status: readRecognizerStatus() };
}

/** Symmetric explicit residency; loading never changes the desired recognizer. */
export async function setRecognizerResidency(engine: Recognizer, action: "load" | "unload", deps: RecognizerTransitionDeps = defaults) {
  const current = readRecognizerStatus();
  if (action === "load" && current.desired === engine && current.effective !== null && current.effective !== engine) return selectRecognizer(engine, deps);
  let acquired = false, loading = false, outcome: "accept" | "reject" = "accept", reason: string | undefined;
  try {
    assertRecognizerNotDownloading(engine);
    beginRecognizerMaintenance(); acquired = true;
    if (action === "load" && engine === "parakeet" && deps === defaults && parakeetServer.pid === null) migrateLegacyParakeetRuntime();
    const status = readRecognizerStatus();
    if (action === "load") {
      if (status.desired !== engine || status.effective !== null && status.effective !== engine) throw new Error("select-recognizer-first");
      if (!status.engines[engine].assets_present) throw new Error("assets-not-present");
      loading = true; noteRecognizerEngine(engine, { phase: "loading", error: null });
      await (engine === "parakeet" ? deps.startP() : deps.startW());
      assertRecognizerOwnerOpen(); noteRecognizerEngine(engine, { phase: "ready", available: true, error: null }); noteRecognizerEffective(engine);
    } else {
      try { await (engine === "parakeet" ? deps.stopP() : deps.stopW()); }
      catch { markRecognizerCleanupUnconfirmed(engine); throw new Error("cleanup-unconfirmed"); }
      confirmRecognizerCleanup(engine); noteRecognizerEngine(engine, { phase: "sleeping", error: null });
    }
  } catch (error) {
    outcome = "reject"; reason = error instanceof Error ? error.message : "residency-failed";
    if (loading) {
      try { await (engine === "parakeet" ? deps.stopP() : deps.stopW()); confirmRecognizerCleanup(engine); }
      catch { markRecognizerCleanupUnconfirmed(engine); reason = "cleanup-unconfirmed"; }
      noteRecognizerEngine(engine, { phase: "error", available: false, error: reason });
    }
  }
  finally { if (acquired) finishRecognizerTransition(); }
  return { outcome, ...(reason ? { reason } : {}), recognizer_status: readRecognizerStatus() };
}
