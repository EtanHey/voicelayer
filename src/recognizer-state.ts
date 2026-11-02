/** Daemon-owned preference and observable state; no model/probe in a read. */
import { mkdirSync, readFileSync, renameSync, unlinkSync } from "fs";
import { dirname, join } from "path";
import { getStateDir, safeWriteFileSync } from "./paths";
import { readRecognizerAssets } from "./recognizer-assets";
import { modelIdleSeconds } from "./model-residency";
export type Recognizer = "parakeet" | "whisper";
export type RecognizerPhase = "loading" | "ready" | "sleeping" | "error";
export interface RecognizerDownloadStatus { state: "idle" | "downloading" | "verifying" | "runtime" | "complete" | "cancelled" | "error"; received_bytes: number; total_bytes: number; error: string | null }
export interface RecognizerStatus {
  revision: number; desired: Recognizer; effective: Recognizer | null; phase: RecognizerPhase;
  engines: Record<Recognizer, { assets_present: boolean; disk_bytes: number; download: RecognizerDownloadStatus; phase: RecognizerPhase; available: boolean | null; error: string | null }>;
  fallback_reason: string | null; switch_allowed: boolean; switch_refusal_reason: string | null;
  idle_unload_seconds: number; source: "settings" | "env" | "default";
}
export function recognizerSettingsPath(): string { return join(getStateDir(), "stt-settings.json"); }
export function recognizerPreference(): { recognizer: Recognizer; source: RecognizerStatus["source"] } {
  const env = process.env.QA_VOICE_STT_BACKEND?.trim().toLowerCase();
  if (env && env !== "auto") return { recognizer: env === "parakeet" || env === "parakeet-resident" ? "parakeet" : "whisper", source: "env" };
  try {
    const value = JSON.parse(readFileSync(recognizerSettingsPath(), "utf8"));
    if (value.version === 1 && (value.recognizer === "parakeet" || value.recognizer === "whisper")) return { recognizer: value.recognizer, source: "settings" };
  } catch { /* The untouched default preserves existing auto selection. */ }
  return { recognizer: "whisper", source: "default" };
}
export function persistRecognizer(recognizer: Recognizer): void {
  if (recognizerPreference().source === "env") throw new Error("environment-override");
  const path = recognizerSettingsPath(), tmp = `${path}.${process.pid}.tmp`;
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  safeWriteFileSync(tmp, JSON.stringify({ version: 1, recognizer }) + "\n");
  try { renameSync(tmp, path); } finally { try { unlinkSync(tmp); } catch {} }
}
let revision = 0, effective: Recognizer | null = null, phase: RecognizerPhase = "sleeping", fallbackReason: string | null = null;
let requests = 0, transition = false, queuedRequests = 0;
let maintenance: Promise<void> | null = null;
let releaseMaintenance: (() => void) | null = null;
const owner = new AbortController();
export const recognizerOwnerSignal = owner.signal;
export function recognizerOwnerClosed(): boolean { return owner.signal.aborted; }
export function assertRecognizerOwnerOpen(): void { if (recognizerOwnerClosed()) throw new Error("owner-shutdown"); }
export function closeRecognizerOwner(): void {
  if (recognizerOwnerClosed()) return;
  owner.abort();
  effective = null;
  for (const engine of Object.values(engines)) {
    if (engine.phase === "loading" || engine.phase === "ready") Object.assign(engine, { phase: "error", available: false, error: "owner-shutdown" });
  }
  phase = "error"; publish();
}
export async function joinRecognizerMaintenance(): Promise<void> { if (maintenance) await maintenance; }

const cleanupBarriers = new Set<Recognizer>();
export interface RecognizerRecovery { engine: Recognizer; failed: Recognizer; attempt: unknown; evidencePath?: string }
let recovery: RecognizerRecovery | null = null;
export function recognizerRecovery(): RecognizerRecovery | null { return recovery; }
export function setRecognizerRecovery(value: RecognizerRecovery | null): void { recovery = value; }
export function recognizerRecoveryWhisper(): RecognizerRecovery | null { return recovery?.engine === "whisper" ? recovery : null; }
export function setRecognizerRecoveryWhisper(value: { attempt: unknown } | null): void {
  recovery = value ? { engine: "whisper", failed: "parakeet", attempt: value.attempt } : null;
}
export function markRecognizerCleanupUnconfirmed(engine: Recognizer): void { cleanupBarriers.add(engine); publish(); }
export function confirmRecognizerCleanup(engine: Recognizer): void { if (cleanupBarriers.delete(engine)) publish(); }
const engines: Record<Recognizer, Omit<RecognizerStatus["engines"][Recognizer], "assets_present" | "disk_bytes">> = {
  parakeet: { phase: "sleeping", available: null, error: null, download: { state: "idle", received_bytes: 0, total_bytes: 0, error: null } },
  whisper: { phase: "sleeping", available: null, error: null, download: { state: "idle", received_bytes: 0, total_bytes: 0, error: null } },
};
let busyProbe: () => string | null = () => null;
const listeners = new Set<(status: RecognizerStatus) => void>();
export function configureRecognizerBusyProbe(probe: () => string | null): void { busyProbe = probe; }
export function recognizerSwitchRefusal(): string | null {
  if (recognizerOwnerClosed()) return "owner-shutdown";
  if (requests || queuedRequests) return "request-active";
  if (transition) return "transition-active";
  if (cleanupBarriers.size || Object.values(engines).some(engine => engine.error === "cleanup-unconfirmed")) return "cleanup-unconfirmed";
  if (recognizerPreference().source === "env") return "environment-override";
  return busyProbe();
}
export function readRecognizerStatus(): RecognizerStatus {
  const preference = recognizerPreference(), reason = recognizerSwitchRefusal();
  return { revision, desired: preference.recognizer, effective, phase,
    engines: { parakeet: { ...engines.parakeet, ...readRecognizerAssets("parakeet") }, whisper: { ...engines.whisper, ...readRecognizerAssets("whisper") } },
    fallback_reason: fallbackReason, switch_allowed: reason === null, switch_refusal_reason: reason,
    idle_unload_seconds: modelIdleSeconds(), source: preference.source };
}
function publish(): void {
  revision++;
  for (const listener of listeners) { try { listener(readRecognizerStatus()); } catch { /* UI observation cannot replace provider errors. */ } }
}
export function onRecognizerStatusChange(listener: (status: RecognizerStatus) => void): () => void { listeners.add(listener); return () => listeners.delete(listener); }
export function noteRecognizerEngine(engine: Recognizer, value: Partial<RecognizerStatus["engines"][Recognizer]>): void {
  if (recognizerOwnerClosed() && (value.phase === "ready" || value.phase === "loading")) return;
  Object.assign(engines[engine], value);
  if (engine === effective || (!effective && engine === recognizerPreference().recognizer)) phase = engines[engine].phase;
  publish();
}
export function noteRecognizerEffective(engine: Recognizer | null, reason: string | null = null): void {
  if (recognizerOwnerClosed() && engine !== null) return;
  effective = engine; fallbackReason = reason; phase = engines[engine ?? recognizerPreference().recognizer].phase; publish();
}
export function beginRecognizerTransition(): void {
  const refusal = recognizerSwitchRefusal(); if (refusal) throw new Error(refusal);
  transition = true; publish();
}
/** Legacy model mutations share exclusion without changing env override policy. */
export function beginRecognizerMaintenance(): void {
  assertRecognizerOwnerOpen();
  if (requests || queuedRequests) throw new Error("request-active");
  if (transition) throw new Error("transition-active");
  if (cleanupBarriers.size) throw new Error("cleanup-unconfirmed");
  const busy = busyProbe(); if (busy) throw new Error(busy);
  transition = true;
  maintenance = new Promise<void>(resolve => { releaseMaintenance = resolve; });
  publish();
}
export function recheckRecognizerBusy(): void { assertRecognizerOwnerOpen(); const busy = busyProbe(); if (busy) throw new Error(busy); }
export function finishRecognizerTransition(): void {
  transition = false;
  const release = releaseMaintenance; maintenance = null; releaseMaintenance = null;
  release?.(); publish();
}
export function beginRecognizerRequest(): void {
  if (recognizerOwnerClosed()) throw new Error("STT owner is shut down");
  if (transition) throw new Error("Recognizer transition active");
  if (cleanupBarriers.size || Object.values(engines).some(engine => engine.error === "cleanup-unconfirmed")) throw new Error("Recognizer cleanup unconfirmed");
  requests++; publish();
}
export function finishRecognizerRequest(): void { requests = Math.max(0, requests - 1); publish(); }

/** Admitted capture waits only for legacy maintenance, never a picker switch.
 * Count the waiter before yielding so another mutation cannot steal the gap. */
export async function beginRecognizerRequestAfterMaintenance(signal?: AbortSignal): Promise<void> {
  queuedRequests++; publish();
  const aborted = () => new Error("STT request cancelled or owner is shut down");
  let onAbort: (() => void) | undefined;
  const cancelled = new Promise<never>((_, reject) => { onAbort = () => reject(aborted()); });
  try {
    if (signal?.aborted || recognizerOwnerClosed()) throw aborted();
    signal?.addEventListener("abort", onAbort!, { once: true });
    owner.signal.addEventListener("abort", onAbort!, { once: true });
    if (maintenance) await Promise.race([maintenance, cancelled]);
    if (signal?.aborted || recognizerOwnerClosed()) throw aborted();
    beginRecognizerRequest();
  } finally {
    signal?.removeEventListener("abort", onAbort!); owner.signal.removeEventListener("abort", onAbort!);
    queuedRequests--; publish();
  }
}

export function assertRecognizerCleanupConfirmed(): void {
  if (cleanupBarriers.size || Object.values(engines).some(engine => engine.error === "cleanup-unconfirmed")) throw new Error("cleanup-unconfirmed");
}
