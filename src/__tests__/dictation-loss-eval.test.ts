import { describe, expect, test } from "bun:test";
import { alignLoss, lossWords, stageEdges } from "../dictation-loss-eval";

describe("offline loss alignment (synthetic public text)", () => {
  test("retains currency, percentages and compact numbers", () => {
    expect(lossWords("$42,016 42k 12%" )).toEqual(["$42016", "42k", "12%"]);
    expect(alignLoss("42k tasks are ready now today", "tasks are ready now today")[0]?.tags).toContain("number/unit");
  });
  test("classifies a repeated lost ending without deduplicating it", () => {
    const edits = alignLoss("go far far beyond", "go");
    expect(edits.filter(e => e.kind === "delete")).toHaveLength(3);
    expect(edits.every(e => e.tags.includes("ending/tail"))).toBe(true);
    expect(edits.some(e => e.tags.includes("repetition/retraction"))).toBe(true);
  });
  test("separates substitutions, insertions and deletion candidates", () => {
    expect(alignLoss("small task", "large task")[0]?.kind).toBe("substitute");
    expect(alignLoss("task", "new task")[0]?.kind).toBe("insert");
    expect(alignLoss("maybe run", "run")[0]?.tags).toContain("filler/hedge");
    expect(alignLoss("no wait run", "run")[0]?.tags).toContain("repetition/retraction");
  });
  test("attributes changes to ordered replay edges, leaving paragraph whitespace neutral", () => {
    const edges = stageEdges([{ name: "raw", text: "um one task" }, { name: "dictionary", text: "um one task." },
      { name: "polish", text: "One task." }, { name: "paragraphs", text: "One\n task." }]);
    expect(edges.map(e => e.edits.length)).toEqual([0, 1, 0]);
    expect(edges[1]?.from).toBe("dictionary");
  });
  test("does not invent seam evidence and handles empty hypotheses", () => {
    expect(alignLoss("start bridge end", "start end")[0]?.tags).not.toContain("seam/chunk-boundary");
    expect(alignLoss("start bridge end", "start end", [1])[0]?.tags).toContain("seam/chunk-boundary");
    expect(alignLoss("", "")).toEqual([]);
    expect(alignLoss("hello", "")[0]?.kind).toBe("delete");
  });
});

describe("live-host admission with synthetic sockets and state", () => {
  test("refuses active and malformed state; accepts an idle living owner", async () => {
    const { idleState } = await import("../../scripts/dictation-loss-eval");
    const { createServer } = await import("node:net");
    const { writeFileSync, unlinkSync } = await import("node:fs");
    const { join } = await import("node:path");
    const root = process.env.VOICELAYER_TEST_RUN_ROOT!;
    const socket = join(root, "d.sock"), state = join(root, "d.json");
    const server = createServer(client => client.end());
    await new Promise<void>(r => server.listen(socket, r));
    try {
      writeFileSync(state, JSON.stringify({ state: "recording", pid: process.pid, updated_at: new Date().toISOString() }));
      await expect(idleState(socket, state)).rejects.toThrow("BUSY: recording");
      writeFileSync(state, "{}");
      await expect(idleState(socket, state)).rejects.toThrow();
      writeFileSync(state, JSON.stringify({ state: "idle", pid: process.pid, updated_at: new Date().toISOString() }));
      await idleState(socket, state);
    } finally { await new Promise<void>(r => server.close(() => r())); unlinkSync(state); }
  });
});
