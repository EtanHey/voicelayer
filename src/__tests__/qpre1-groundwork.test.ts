import { describe, expect, it } from "bun:test";
import { SelectionReadQueue, type QueuedSelectionRead } from "../selection-read-queue";

// Proposed fourth constructor dependency. Synthetic memory-only audio ownership.
const read = (requestId: string): QueuedSelectionRead => ({ requestId, text: `Synthetic ${requestId}`, textHash: requestId, profile: "auto" });
function harness(fail = false) {
  const synthesized: string[] = [], disposed: string[] = [], played: string[] = [];
  const hooks = {
    prepare: async (item: QueuedSelectionRead, signal: AbortSignal) => {
      synthesized.push(item.requestId);
      if (fail) throw new Error("synthetic prefetch failure");
      signal.addEventListener("abort", () => disposed.push(item.requestId), { once: true });
      return { dispose: () => disposed.push(item.requestId) };
    },
  };
  const queue = new SelectionReadQueue((item) => played.push(item.requestId), () => {}, 10,
    hooks);
  queue.submit(read("A"), true); // A owns playback until explicit settled.
  queue.submit(read("B"), true);
  return { queue, synthesized, disposed, played };
}
const flush = async () => { for (let i = 0; i < 8; i++) await Promise.resolve(); };

describe("QPRE1 groundwork RED contracts", () => {
  it("synthesizes B before A ends, never C", async () => {
    const h = harness(); h.queue.submit(read("C"), true); await flush();
    expect(h.played).toEqual(["A"]);
    expect(h.synthesized).toEqual(["B"]);
    h.queue.clear();
  });
  for (const reason of ["Stop", "Hide", "agent preemption", "idle Cancel"]) {
    it(`${reason} clear seam discards prepared B`, async () => {
      const h = harness(); await flush(); h.queue.clear(); await flush();
      expect(h.disposed).toContain("B");
      expect(h.played).toEqual(["A"]);
      expect(h.queue.pendingCount).toBe(0);
    });
  }
  it("prefetch failure falls back to normal start on advance", async () => {
    const h = harness(true); await flush();
    expect(h.queue.pendingCount).toBe(1);
    expect(h.queue.next("A")).toBe("advanced");
    expect(h.played).toEqual(["A", "B"]);
    expect(h.synthesized).toEqual(["B"]);
    h.queue.clear();
  });
});
