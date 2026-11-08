import { describe, expect, test } from "bun:test";
import { alignLoss, lossWords, stageEdges, referenceComparisons, referenceSkipReason, eligibleReplayEdges, summarizePolishReplays } from "../dictation-loss-eval";

describe("offline loss alignment (synthetic public text)", () => {
  test("retains currency, percentages and compact numbers", () => {
    expect(lossWords("$42,016 42k 12%" )).toEqual(["$42016", "42k", "12%"]);
    expect(alignLoss("42k tasks are ready now today", "tasks are ready now today")[0]?.tags).toContain("number/unit");
  });
  test("retains standalone currency and percent units", () => {
    expect(lossWords("price $ 42 then 12 %")).toEqual(["price", "$", "42", "then", "12", "%"]);
    expect(alignLoss("change 12 % today", "change 12 today").find(e => e.before === "%")?.tags).toContain("number/unit");
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

describe("review regressions: real deletion suffix and numbers", () => {
  test("all twelve words in a lost ending are tail deletions", () => {
    const before = "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron";
    const edits = alignLoss(before, "alpha beta gamma");
    expect(edits).toHaveLength(12);
    expect(edits.every(e => e.kind === "delete" && e.tags.includes("ending/tail"))).toBe(true);
  });
  test("a later aligned word prevents an interior deletion from being a tail", () => {
    const words = "alpha beta gamma delta epsilon zeta eta theta iota";
    expect(alignLoss(words, "beta gamma delta epsilon zeta eta theta iota")[0]?.tags).not.toContain("ending/tail");
    expect(alignLoss(words, "alpha gamma delta epsilon zeta eta theta iota")[0]?.tags).not.toContain("ending/tail");
    const suffix = alignLoss(words, "alpha");
    expect(suffix).toHaveLength(8);
    expect(suffix[0]?.index).toBe(1);
    expect(suffix.every(e => e.tags.includes("ending/tail"))).toBe(true);
    expect(alignLoss("alpha beta gamma", "alpha beta delta")[0]?.tags).not.toContain("ending/tail");
  });
  test.each(["eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety", "billion", "cents", "k"])("recognizes numeric/unit word %s", word => {
    expect(alignLoss(`we have ${word} tasks`, "we have tasks")[0]?.tags).toContain("number/unit");
  });
  test("commas normalize grouped thousands but never merge digit lists", () => {
    expect(lossWords("steps 1,2,3 then 1,234,56")).toEqual(["steps", "1", "2", "3", "then", "1", "234", "56"]);
    expect(lossWords("$12,345,678.50 12.5% 30,016")).toEqual(["$12345678.50", "12.5%", "30016"]);
  });
});

describe("review regressions: comparison and polish evidence", () => {
  test("ungated closers cannot become decoder-tail losses in the gated comparison", () => {
    const result = referenceComparisons({ ungated: "ship it now. Thank you.", gated: "ship it now.", raw: "Ship it now.", finalText: "Ship it now." });
    expect(result.referenceGatedVsRaw).toEqual([]);
    expect(result.referenceVsFinal).toEqual([]);
    expect(result.referenceUngatedVsRaw).toHaveLength(2);
  });
  test("a real gated-reference ending is compared directly with raw, independently of finalization", () => {
    const result = referenceComparisons({ ungated: "ship it far far beyond. Thank you.", gated: "ship it far far beyond.", raw: "ship it", finalText: "Ship it." });
    expect(result.referenceGatedVsRaw.map(e => e.before)).toEqual(["far", "far", "beyond"]);
    expect(result.referenceGatedVsRaw.every(e => e.kind === "delete" && e.tags.includes("ending/tail"))).toBe(true);
  });
  test("failed/timeout, rejected and unavailable observations never count as applied polish", () => {
    const edges = stageEdges([{ name: "dictionary_rules", text: "keep every word" }, { name: "polish", text: "keep word" }]);
    const applied = { status: "applied", edges } satisfies Parameters<typeof summarizePolishReplays>[0][number];
    const rejected = { status: "rejected", edges } satisfies Parameters<typeof summarizePolishReplays>[0][number];
    const failed = { status: "failed", failureKind: "timeout", edges } satisfies Parameters<typeof summarizePolishReplays>[0][number];
    const unavailable = { status: "unavailable", edges } satisfies Parameters<typeof summarizePolishReplays>[0][number];
    const summary = summarizePolishReplays([applied, rejected, failed, unavailable]);
    expect(summary.applied).toBe(1);
    expect(summary.total).toBe(4);
    expect(summary.appliedDeletedTokens).toBe(1);
    expect(summary.statuses).toEqual({ applied: 1, rejected: 1, failed: 1, unavailable: 1 });
    expect(summary.failures).toEqual({ timeout: 1 });
    expect(eligibleReplayEdges(rejected)).toEqual([]);
    expect(eligibleReplayEdges(failed)).toEqual([]);
    expect(summarizePolishReplays([failed, rejected]).appliedDeletedTokens).toBeNull();
  });
  test("an empty reference has an explicit per-take skip reason", () => {
    expect(referenceSkipReason(" \n")).toContain("empty independent reference");
    expect(referenceSkipReason("public fixture")).toBeNull();
  });
});

describe("review regressions: cache and filesystem boundaries", () => {
  test("cache mismatch is friendly and an empty reference remains parseable", async () => {
    const { parseDecodeCache } = await import("../../scripts/dictation-loss-eval");
    const cache = { decodeIdentity: "old", hash: "audio", native: null, nativeError: null, reference: "", gated: "", outro: "", segments: [] };
    expect(() => parseDecodeCache(cache, { decodeIdentity: "new", hash: "audio" })).toThrow("fresh private output directory");
    expect(() => parseDecodeCache({}, { decodeIdentity: "old", hash: "audio" })).toThrow("Decode cache is invalid");
    expect(referenceSkipReason(parseDecodeCache(cache, { decodeIdentity: "old", hash: "audio" }).reference)).toContain("empty independent reference");
  });
  test("validates an output without creating it and anchors cache independently of cwd", async () => {
    const { validateOutputPath, repoCacheDirectory } = await import("../../scripts/dictation-loss-eval");
    const { join, resolve } = await import("node:path");
    const { existsSync } = await import("node:fs");
    const root = process.env.VOICELAYER_TEST_RUN_ROOT!;
    const invalid = join(root, "not-a-private-output", "new");
    expect(() => validateOutputPath(invalid, join(root, "archive"))).toThrow("private docs.local");
    expect(existsSync(invalid)).toBe(false);
    const valid = join(root, "docs.local", "new");
    expect(validateOutputPath(valid, join(root, "archive"))).toBe(valid);
    expect(existsSync(valid)).toBe(false);
    const previous = process.cwd();
    try { process.chdir(root); expect(repoCacheDirectory()).toBe(resolve(import.meta.dir, "../../.build.noindex/dictation-loss-cache")); }
    finally { process.chdir(previous); }
  });
  test("frozen cohort excludes later takes and refuses missing or duplicate IDs", async () => {
    const { selectFrozenTakes } = await import("../../scripts/dictation-loss-eval");
    const takes = [{ id: "first" }, { id: "second" }, { id: "later" }];
    expect(selectFrozenTakes(takes, ["first", "second"])).toEqual(takes.slice(0, 2));
    expect(() => selectFrozenTakes(takes, ["missing"])).toThrow("missing from archive");
    expect(() => selectFrozenTakes(takes, ["first", "first"])).toThrow("unique");
    expect(() => selectFrozenTakes(takes, [])).toThrow("nonempty");
  });
});

test("offline admission backs off for dictation but never retries an unavailable host", async () => {
  const { waitForIdle } = await import("../../scripts/dictation-loss-eval");
  let checks = 0, pauses = 0;
  await waitForIdle(async () => { if (++checks === 1) throw new Error("BUSY: recording; resume later"); }, async () => { pauses++; });
  expect(checks).toBe(2); expect(pauses).toBe(1);
  checks = 0;
  await expect(waitForIdle(async () => { checks++; throw new Error("Live socket unavailable"); }, async () => { pauses++; })).rejects.toThrow("unavailable");
  expect(checks).toBe(1); expect(pauses).toBe(1);
});
