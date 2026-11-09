import { afterEach, expect, spyOn, test } from "bun:test";
import { readFileSync } from "node:fs";
import { STOP_FILE } from "../paths";
import { beginCaptureTrace, captureLifecycle, writeCaptureStop } from "../capture-lifecycle";
import { clearStopSignal } from "../session-booking";

afterEach(clearStopSignal);
test("stop writer tracing preserves payload and original target on every route", () => {
  const rows: Record<string, unknown>[] = [];
  const spy = spyOn(console, "error").mockImplementation(line => {
    rows.push(JSON.parse(String(line).slice(String(line).indexOf("{"))));
  });
  try {
    beginCaptureTrace("live");
    const routes: Array<Parameters<typeof writeCaptureStop>[1]> = ["scoped", "fallback-to-live", "buffered-in-opening", "legacy-text", "cancel"];
    for (const route of routes) {
      const payload = route === "legacy-text" ? "legacy text control" : JSON.stringify({ take_id: "live", cancelled: route === "cancel" });
      writeCaptureStop(payload, route, { command_take_id: "old", command_id: "control", scope: "capture", physical_press: false, cancelled: route === "cancel" }, "live");
      expect(readFileSync(STOP_FILE, "utf8")).toBe(payload);
      expect(rows.at(-1)).toMatchObject({ event: "write-stop", route, command_take_id: "old", stamped_take_id: "live" });
    }
    // A natural recorder EOF can precede finish. Keep its accept epoch available.
    captureLifecycle("exit", { take_id: "live" });
    captureLifecycle("finish", { take_id: "live" });
    expect(rows.every(row => Number.isFinite(row.t_ms) && Number.isFinite(row.monotonic_ms) && Number.isFinite(row.since_accept_ms))).toBe(true);
    expect(rows.every((row, i) => i === 0 || Number(row.monotonic_ms) >= Number(rows[i - 1]!.monotonic_ms))).toBe(true);
  } finally { spy.mockRestore(); }
});
