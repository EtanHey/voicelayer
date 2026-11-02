import { expect, test } from "bun:test";
import { readFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { createHash } from "node:crypto";
import { z } from "zod";
import { contractSchema, fixture, wireCase } from "./runtime-adapter";

const root = new URL("../../", import.meta.url);
const generated = new URL(".build.noindex/record-while-processing/corpus.json", root);
const corpusPath = existsSync(fileURLToPath(generated)) ? generated : new URL("formal/record-while-processing/corpus.json", root);
const corpusBytes = readFileSync(corpusPath);
const pin = z.object({ sha256: z.string() }).parse(JSON.parse(readFileSync(new URL("formal/record-while-processing/results/corpus.json", root), "utf8")));
if (createHash("sha256").update(corpusBytes).digest("hex") !== pin.sha256) throw new Error("Corpus checksum mismatch");
const corpus = z.object({ modelSHA256: z.string(), wire: z.array(wireCase).min(4) }).parse(JSON.parse(readFileSync(corpusPath, "utf8")));
const contract = contractSchema.parse(JSON.parse(readFileSync(new URL("formal/runtime-contract.json", root), "utf8")));
const baseline = z.object({ divergencePins: z.record(z.string(), z.object({ sha256: z.string(), count: z.number() })) }).parse(
  JSON.parse(readFileSync(new URL("formal/record-while-processing/results/conformance.json", root), "utf8")));
const replySchema = z.object({ outcome: z.enum(["accept", "reject", "noop"]) });

test("default pipeline corpus binds both policies to the checked spec", () => {
  const spec = readFileSync(new URL("formal/record-while-processing/RecordWhileProcessing.tla", root));
  expect(createHash("sha256").update(spec).digest("hex")).toBe(corpus.modelSHA256);
  expect(new Set(corpus.wire.map(row => row.policy))).toEqual(new Set(["Current", "Fixed"]));
  expect(new Set(corpus.wire.map(row => row.origin))).toEqual(new Set(["socket", "click", "Escape"]));
  expect(corpus.wire.some(row => row.policy === "Fixed" && row.requestId === "stale")).toBe(true);
  for (const policy of ["Current", "Fixed"]) {
    const rows = corpus.wire.filter(row => row.policy === policy);
    expect(new Set(rows.map(row => row.origin))).toEqual(new Set(["socket", "click", "Escape"]));
    for (const command of ["record", "cancel"]) expect(rows.some(row => row.command === command)).toBe(true);
  }
  expect(corpus.wire.some(row => row.policy === "Fixed" && row.command === "record" && row.phase === "transcribing")).toBe(true);
  expect(corpus.wire.some(row => row.policy === "Fixed" && row.target === "B" && row.before.A === "transcribing" && row.before.B === "recording")).toBe(true);
});
for (const policy of ["Current", "Fixed"] as const) {
  for (const command of ["record", "cancel"] as const) {
    test(`${policy} ${command}: all graph contexts through the real socket handler`, async () => {
      const runtime = fixture(); const errors: string[] = [];
      const cases = corpus.wire.filter(row => row.policy === policy && row.command === command);
      expect(cases.length).toBeGreaterThan(0);
      try {
        for (const row of cases) {
          const actual = await runtime.dispatch(row, contract);
          const tag = JSON.stringify(row);
          const reply = replySchema.safeParse(actual.reply);
          if (!reply.success || reply.data.outcome !== row.outcome) errors.push(`${tag}: ack actual=${JSON.stringify(actual.reply)} expected=${row.outcome}`);
          const signal = z.array(z.array(z.unknown())).parse(actual.signals);
          const expected = row.token === "none" ? [] : row.token === "global" ? [[]] : [[contract.captureIds[row.token]]];
          if (JSON.stringify(signal) !== JSON.stringify(expected)) errors.push(`${tag}: cancellation identity actual=${JSON.stringify(signal)} expected=${JSON.stringify(expected)}`);
          if (row.token !== "none" && row.token !== "global" && actual.stop && !actual.stop.includes(String(contract.captureIds[row.token])))
            errors.push(`${tag}: unscoped stop signal`);
        }
      } finally { runtime.close(); }
      console.info(`${policy}/${command}: replayed ${cases.length} TLC graph contexts; ${errors.length} divergences`);
      if (policy.toLowerCase() === contract.pipelinePolicy) expect(errors).toEqual([]);
      else if (policy === "Fixed") {
        const family = `${policy}/${command}`;
        const sha256 = createHash("sha256").update(errors.sort().join("\n")).digest("hex");
        console.info(`LANEG_DIVERGENCE ${family}|${errors.length}|${sha256}`);
        // Strict assertions outside an expected-failure wrapper: extra/changed divergences FAIL.
        expect({ count: errors.length, sha256 }).toEqual(baseline.divergencePins[family]);
        expect(errors.length).toBeGreaterThan(0);
      } else expect(errors.length).toBeGreaterThan(0); // Executed historical comparison after the implementation flip.
    });
  }
}
