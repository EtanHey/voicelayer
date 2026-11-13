import { setTimeout as sleep } from "node:timers/promises";
import { warmSelectedRecognizer } from "./recognizer-controller";
import { recognizerOwnerSignal } from "./recognizer-state";
import { UpdateBusyError, VoiceAdmissionCancelledError, withFreshAsyncVoiceAdmission } from "./update-gate-admission";
import { readInstallerGateState } from "./update-gate-storage";

type Stage = "admission" | "recheck" | "warmup";
type Reason = "UPDATE_BUSY" | "GATE_NOT_OPEN" | "ADMISSION_CANCELLED" | "ADMISSION_FAILED" | "WARMUP_FAILED" | "WARMUP_REJECTED" | "ASSETS_UNAVAILABLE" | "OWNER_SHUTDOWN" | "WAIT_TIMEOUT";
class BootWaitExpired extends Error {}
class BootGateNotOpen extends Error {}

/** Boot-only deferred work. Never hold admission while waiting for install COMPLETE.
 * The observation is only a hint: every retry takes a fresh ordinary admission
 * and verifies OPEN again in its synchronous body, before starting any provider. */
export async function runRecognizerBootWarmup(warm = warmSelectedRecognizer,
  { signal = recognizerOwnerSignal, maxWaitMs = 120_000, pollMs = 100 }:
  { signal?: AbortSignal; maxWaitMs?: number; pollMs?: number } = {}): Promise<void> {
  const deadline = performance.now() + maxWaitMs;
  let deferred = false, stage: Stage = "admission", bodyEntered = false;
  const emit = (event: string, reason: Reason | null, outcome: string) => console.error("[voicelayer] " + JSON.stringify({
    event, stage, reason, outcome, body_entered: bodyEntered, pid: process.pid, at: new Date().toISOString(),
  }));
  const abandon = (reason: Reason) => emit("recognizer_boot_warmup_deferred", reason, "abandoned");
  const open = () => {
    try { return readInstallerGateState().kind === "OPEN"; }
    catch { return false; } // Contention or unreadable evidence never authorizes a boot retry.
  };
  for (;;) {
    if (signal.aborted) { abandon("OWNER_SHUTDOWN"); return; }
    if (deferred && performance.now() >= deadline) { abandon("WAIT_TIMEOUT"); return; }
    if (!deferred || open()) {
      stage = "admission"; bodyEntered = false;
      try {
        const result = await withFreshAsyncVoiceAdmission(() => {
          bodyEntered = true; stage = "recheck";
          if (signal.aborted) throw new VoiceAdmissionCancelledError();
          if (deferred && performance.now() >= deadline) throw new BootWaitExpired();
          if (!open()) throw new BootGateNotOpen();
          stage = "warmup";
          return warm(); // Resolves the current selection here, never at the original boot.
        }, { maxWaitMs: Math.max(0, Math.min(1500, deadline - performance.now())) });
        if (deferred) {
          if (signal.aborted) abandon("OWNER_SHUTDOWN");
          else if (result?.outcome === "accept") emit("recognizer_boot_warmup_deferred", null, "accept");
          else abandon(result ? "WARMUP_REJECTED" : "ASSETS_UNAVAILABLE");
        }
        return;
      } catch (error) {
        const failedStage = stage as Stage; // The admitted callback changes this across the await.
        // Type alone is insufficient: a provider/body failure is never retried.
        if ((error instanceof UpdateBusyError || error instanceof BootGateNotOpen) && failedStage !== "warmup" && !signal.aborted) {
          if (!deferred) emit("recognizer_boot_warmup_failure", error instanceof UpdateBusyError ? "UPDATE_BUSY" : "GATE_NOT_OPEN", "deferred");
          deferred = true;
        } else {
          const reason: Reason = signal.aborted ? "OWNER_SHUTDOWN" : error instanceof BootWaitExpired ? "WAIT_TIMEOUT" :
            error instanceof VoiceAdmissionCancelledError ? "ADMISSION_CANCELLED" : failedStage === "warmup" ? "WARMUP_FAILED" : "ADMISSION_FAILED";
          emit("recognizer_boot_warmup_failure", reason, "failed");
          if (deferred) abandon(reason);
          return;
        }
      }
    }
    // No admission or provider resources exist across this cancellable wait.
    try { await sleep(Math.max(1, Math.min(pollMs, deadline - performance.now())), undefined, { signal }); }
    catch { abandon("OWNER_SHUTDOWN"); return; }
  }
}
