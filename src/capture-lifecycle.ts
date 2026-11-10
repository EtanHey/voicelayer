import { STOP_FILE, safeWriteFileSync } from "./paths";

const accepted = new Map<string, number>();
export function beginCaptureTrace(takeID: string): void {
  accepted.set(takeID, performance.now());
  // Retain EOF epochs through finish, without growing across an unbounded session.
  const oldest = accepted.keys().next();
  if (accepted.size > 128 && !oldest.done) accepted.delete(oldest.value);
  captureLifecycle("record-accept", { take_id: takeID });
}
export function captureLifecycle(event: string, fields: Record<string, unknown>): void {
  const now = performance.now();
  const start = typeof fields.take_id === "string" ? accepted.get(fields.take_id) : undefined;
  console.error("[voicelayer][capture-lifecycle] " + JSON.stringify({
    ...fields, event, t_ms: Date.now(), monotonic_ms: now,
    since_accept_ms: start === undefined ? null : now - start,
  }));
}
export function writeCaptureStop(payload: string, route: "scoped" | "fallback-to-live" | "buffered-in-opening" | "legacy-text" | "cancel", origin: Record<string, unknown>, stampedTakeID?: string | null): void {
  safeWriteFileSync(STOP_FILE, payload);
  captureLifecycle("write-stop", { ...origin, route, signal_file: STOP_FILE,
    take_id: stampedTakeID ?? null, stamped_take_id: stampedTakeID ?? null });
}
