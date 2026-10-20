import { describe, expect, it } from "bun:test";
import { SELECTION_READ_QUEUE_LIMIT, SelectionReadQueue, type QueuedSelectionRead } from "../selection-read-queue";

const read = (id: string): QueuedSelectionRead => ({ requestId: id, text: `text ${id}`, textHash: "a".repeat(64), profile: "auto" });

function harness(startFails = () => false) {
  const started: string[] = [];
  const published: { count: number; current_request_id: string | null }[] = [];
  const queue = new SelectionReadQueue((item) => {
    if (startFails()) throw new Error("busy");
    started.push(item.requestId);
  }, (state) => published.push(state));
  return { queue, started, published, last: () => published.at(-1) };
}

describe("QUEUE1 selection read queue (TLA3 QUEUE1 gates)", () => {
  it("gate 1: a different selection while the user's read owns playback appends, the current read keeps playing", () => {
    const h = harness();
    expect(h.queue.submit(read("A"), true)).toBe("started");
    expect(h.queue.submit(read("B"), true)).toBe("queued");
    expect(h.started).toEqual(["A"]);
    expect(h.last()).toEqual({ count: 1, current_request_id: "A" });
    expect(h.queue.submit(read("C"), true)).toBe("queued");
    expect(h.last()).toEqual({ count: 2, current_request_id: "A" });
  });

  it("starts at once when no user read is active, and a non-queue speak_text replaces and forgets queued reads", () => {
    const h = harness();
    expect(h.queue.submit(read("A"), true)).toBe("started");
    h.queue.submit(read("B"), true);
    expect(h.queue.submit(read("Z"), false)).toBe("started");
    expect(h.started).toEqual(["A", "Z"]);
    expect(h.queue.pendingCount).toBe(0);
    expect(h.last()).toEqual({ count: 0, current_request_id: null });
  });

  it("gate 3: Next starts the following item at count-1, and Next on the last item stops", () => {
    const h = harness();
    h.queue.submit(read("A"), true); h.queue.submit(read("B"), true); h.queue.submit(read("C"), true);
    expect(h.queue.next("A")).toBe("advanced");
    expect(h.started).toEqual(["A", "B"]);
    expect(h.last()).toEqual({ count: 1, current_request_id: "B" });
    expect(h.queue.next("B")).toBe("advanced");
    expect(h.last()).toEqual({ count: 0, current_request_id: "C" });
    expect(h.queue.next("C")).toBe("stopped");
    expect(h.started).toEqual(["A", "B", "C"]);
    expect(h.last()).toEqual({ count: 0, current_request_id: null });
  });

  it("gate 3: a natural end auto-advances; the last natural end closes the queue", () => {
    const h = harness();
    h.queue.submit(read("A"), true); h.queue.submit(read("B"), true);
    h.queue.settled("A", "completed");
    expect(h.started).toEqual(["A", "B"]);
    expect(h.last()).toEqual({ count: 0, current_request_id: "B" });
    h.queue.settled("B", "completed");
    expect(h.started).toEqual(["A", "B"]);
    expect(h.last()).toEqual({ count: 0, current_request_id: null });
  });

  it("gate 2: Stop clears the whole queue, and a stopped or preempted read never advances", () => {
    const h = harness();
    h.queue.submit(read("A"), true); h.queue.submit(read("B"), true); h.queue.submit(read("C"), true);
    h.queue.clear();
    expect(h.last()).toEqual({ count: 0, current_request_id: null });
    h.queue.settled("A", "stopped");
    expect(h.started).toEqual(["A"]);

    // Agent speech, Ask or a dictation preempting the user's read ends it as stopped: the queue ends too.
    const g = harness();
    g.queue.submit(read("A"), true); g.queue.submit(read("B"), true);
    g.queue.settled("A", "stopped");
    expect(g.started).toEqual(["A"]);
    expect(g.last()).toEqual({ count: 0, current_request_id: null });
  });

  it("gate 5: stale Next and stale settle events never start a removed or old item", () => {
    const h = harness();
    h.queue.submit(read("A"), true); h.queue.submit(read("B"), true); h.queue.submit(read("C"), true);
    expect(h.queue.next("A")).toBe("advanced");
    // A double-clicked Next rendered for A, and A's late settle after Next, are both stale.
    expect(h.queue.next("A")).toBe("stale");
    h.queue.settled("A", "completed");
    expect(h.started).toEqual(["A", "B"]);
    expect(h.last()).toEqual({ count: 1, current_request_id: "B" });
    h.queue.clear();
    expect(h.queue.next("B")).toBe("stale");
    h.queue.settled("B", "completed");
    expect(h.started).toEqual(["A", "B"]);
  });

  it("is bounded: the eleventh queued read is refused as full", () => {
    const h = harness();
    h.queue.submit(read("A"), true);
    for (let i = 0; i < SELECTION_READ_QUEUE_LIMIT; i++) expect(h.queue.submit(read(`q${i}`), true)).toBe("queued");
    expect(h.queue.submit(read("overflow"), true)).toBe("full");
    expect(h.queue.pendingCount).toBe(SELECTION_READ_QUEUE_LIMIT);
  });

  it("a successor that cannot start (recording, Ask, TTS off) clears the queue instead of stranding it", () => {
    let fail = false;
    const h = harness(() => fail);
    h.queue.submit(read("A"), true); h.queue.submit(read("B"), true); h.queue.submit(read("C"), true);
    fail = true;
    h.queue.settled("A", "completed");
    expect(h.started).toEqual(["A"]);
    expect(h.last()).toEqual({ count: 0, current_request_id: null });
  });

  it("SOL-2: a failed read never advances, whatever is queued", () => {
    const h = harness();
    h.queue.submit(read("A"), true); h.queue.submit(read("B"), true); h.queue.submit(read("C"), true);
    h.queue.settled("A", "failed");
    expect(h.started).toEqual(["A"]);
    expect(h.last()).toEqual({ count: 0, current_request_id: null });
  });

  it("SOL-1: a direct selection start owns the queue, so the next different selection appends", () => {
    const h = harness();
    h.queue.own("A");
    expect(h.queue.submit(read("B"), true)).toBe("queued");
    expect(h.started).toEqual([]);
    expect(h.last()).toEqual({ count: 1, current_request_id: "A" });
  });

  it("SOL-3: Next without the owner's identity is stale", () => {
    const h = harness();
    h.queue.submit(read("A"), true); h.queue.submit(read("B"), true);
    expect(h.queue.next("" as string)).toBe("stale");
    expect(h.queue.next(undefined as unknown as string)).toBe("stale");
    expect(h.started).toEqual(["A"]);
  });

  it("D2: F5 suspends the queue; the stopped owner's settle keeps it, nothing auto-starts, Next starts the head", () => {
    const h = harness();
    h.queue.submit(read("A"), true); h.queue.submit(read("B"), true); h.queue.submit(read("C"), true);
    h.queue.suspend();
    h.queue.settled("A", "stopped");
    expect(h.started).toEqual(["A"]);
    expect(h.last()).toEqual({ count: 2, current_request_id: "A" });
    expect(h.queue.next("A")).toBe("advanced");
    expect(h.started).toEqual(["A", "B"]);
    expect(h.last()).toEqual({ count: 1, current_request_id: "B" });
    // From here a natural end advances again.
    h.queue.settled("B", "completed");
    expect(h.started).toEqual(["A", "B", "C"]);
  });

  it("D2: after F5 a new selection plays now with the retained reads behind it; explicit Stop clears them", () => {
    const h = harness();
    h.queue.submit(read("A"), true); h.queue.submit(read("B"), true);
    h.queue.suspend();
    h.queue.settled("A", "stopped");
    expect(h.queue.submit(read("N"), true)).toBe("started");
    expect(h.last()).toEqual({ count: 1, current_request_id: "N" });
    h.queue.suspend();
    h.queue.clear();
    expect(h.last()).toEqual({ count: 0, current_request_id: null });
    // Suspending with nothing waiting is just Stop.
    const g = harness();
    g.queue.submit(read("A"), true);
    g.queue.suspend();
    g.queue.settled("A", "stopped");
    expect(g.queue.next("A")).toBe("stale");
  });

  it("publishes counts only, never queued text", () => {
    const h = harness();
    h.queue.submit(read("A"), true); h.queue.submit(read("B"), true);
    expect(JSON.stringify(h.published)).not.toContain("text ");
  });
});
