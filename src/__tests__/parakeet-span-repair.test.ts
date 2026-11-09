import { expect, spyOn, test } from "bun:test";
import { createHash } from "crypto";
import { readFileSync, writeFileSync } from "fs";
import { ParakeetBackend } from "../parakeet-backend";
import type { ParakeetResponse } from "../parakeet-server";
import type { ParakeetFallbackAttempt } from "../parakeet-attempts";
import { fallbackReasonFromBackend } from "../recording-provenance";
import { finalizeTranscriptionResultForSurface } from "../input";
import { testTmp } from "./setup/test-tmp";

function fixture() {
  const frames = 240 * 16000, bytes = Buffer.alloc(44 + frames * 2);
  bytes.write("RIFF"); bytes.writeUInt32LE(bytes.length - 8, 4); bytes.write("WAVEfmt ", 8);
  bytes.writeUInt32LE(16, 16); bytes.writeUInt16LE(1, 20); bytes.writeUInt16LE(1, 22);
  bytes.writeUInt32LE(16000, 24); bytes.writeUInt32LE(32000, 28); bytes.writeUInt16LE(2, 32); bytes.writeUInt16LE(16, 34);
  bytes.write("data", 36); bytes.writeUInt32LE(frames * 2, 40); bytes.writeInt16LE(1, 44);
  const path = testTmp("span-repair.wav"); writeFileSync(path, bytes);
  const groups = [
    { text: "Keep every original word including fu… no start again before this", start: 29 },
    { text: "after this preserve the entire repeated thought okay okay", start: 41 },
    { text: "Later words survive", start: 110 },
    { text: "another boundary", start: 114 },
    { text: "and the complete final thought survives", start: 234 },
  ];
  const tokens = groups.flatMap(g => g.text.split(" ").map((text, i) => ({ text: ` ${text}`, start: g.start + i, end: g.start + i + .5 })));
  const native: ParakeetResponse = { text: tokens.map(t => t.text).join("").trim(), complete: true,
    input_frames: frames, covered_frames: frames, sample_rate: 16000, last_token_end_s: 239.5,
    inference_s: 0, language: null, raw_token_times: tokens };
  const probabilities = Array.from({ length: Math.ceil(frames / 512) }, (_, i) => i * .032 >= 39.8 && i * .032 < 40.7 ? .9 : .01);
  const speech = { status: "COMPLETE" as const, threshold: .3, inputSha256: createHash("sha256").update(bytes).digest("hex"),
    frames, analyzedFrames: frames, probabilities };
  return { path, native, speech, tokens };
}

async function repair(candidate: string, mode: "speech" | "silence" | "untimed" | "error" | "whole" | "multi" | "mismatch" | "cleanup" | "identity" = "speech") {
  const f = fixture(), clips: Buffer[] = [], retained: ParakeetFallbackAttempt[] = [];
  if (mode === "silence") f.speech.probabilities.fill(.01);
  if (mode === "untimed") f.native.raw_token_times = f.tokens.map(({ start, end }) => ({ start, end }));
  if (mode === "multi") for (let i = Math.ceil(112.8 / .032); i * .032 < 113.7; i++) f.speech.probabilities[i] = .9;
  if (mode === "mismatch") f.native.text += " unmatched";
  if (mode === "whole") f.native.text = "Keep this native thought.";
  if (mode === "identity") f.native.attemptEvidence = { inputPath: "another-recording.wav" };
  const logs = spyOn(console, "error").mockImplementation(() => {});
  try {
    const backend = new ParakeetBackend({ transcribe: async () => f.native, speechProbe: async () => f.speech,
      env: () => ({ QA_VOICE_WHISPER_LANG: "en" }), unload: async () => { if (mode === "cleanup") throw new Error("cleanup unconfirmed"); },
      retainFallback: attempt => { retained.push(attempt); return "retained-test-attempt"; },
      fallbackBackend: { name: "fixture-whisper", isAvailable: async () => true, transcribe: async path => {
        clips.push(readFileSync(path));
        if (mode === "error") throw new Error("provider failed");
        return { text: mode === "multi" && clips.length === 1 ? "words survive recovered clause another boundary" : candidate, backend: "fixture-whisper", durationMs: 1 };
      } },
    });
    const result = await backend.transcribe(f.path);
    return { ...f, result, clips, retained, logs: logs.mock.calls.map(c => c.join(" ")) };
  } finally { logs.mockRestore(); }
}

test("a tiny omission in a long take decodes only padded gap and inserts without replacing any native word", async () => {
  const r = await repair("before this recovered clause after this");
  expect(r.clips).toHaveLength(1);
  expect(r.clips[0]!.readUInt32LE(40) / 32000).toBeLessThanOrEqual(5.5);
  expect(r.result.text).toBe(r.native.text.replace("this after", "this recovered clause after"));
  expect(r.result.backend).toContain("fallback-uncovered-internal");
  expect(r.logs.some(l => l.includes('"reason":"uncovered-internal"') && l.includes('"uncovered_spans_s"'))).toBe(true);
  expect(r.retained.some(a => a.whisper?.text === "before this recovered clause after this")).toBe(true);
  expect(r.retained.some(a => a.deliveryText === r.result.text)).toBe(true);
});

test.each(["silence", "untimed", "error", "mismatch", "cleanup"] as const)("%s keeps every native character when repair cannot qualify", async mode => {
  const r = await repair("must not replace the full take", mode);
  expect(r.result.text).toBe(r.native.text);
  if (mode !== "error") expect(r.clips).toHaveLength(0);
});

test.each([
  "before this " + "one two three four five six ".repeat(12) + "after this",
  "before this " + Array.from({ length: 60 }, (_, i) => `unique${i}`).join(" ") + " after this",
  "unmatched context must never replace the original transcript",
])("unsafe fallback is retained privately and rejected whole, without trimming native words", async candidate => {
  const r = await repair(candidate);
  expect(r.result.text).toBe(r.native.text);
  expect(r.retained.some(a => a.whisper?.text === candidate)).toBe(true);
  expect(r.logs.some(l => l.includes('"accepted":false'))).toBe(true);
  expect(r.logs.join(" ")).not.toContain(candidate);
});

test("uncovered-internal survives backend provenance parsing", () => {
  expect(fallbackReasonFromBackend("parakeet-resident+fallback-uncovered-internal->whisper.cpp+span-repair")).toBe("uncovered-internal");
});

test("a looping whole-input retry for other risks cannot replace returned native words", async () => {
  const candidate = "one two three four five six ".repeat(12);
  const r = await repair(candidate, "whole");
  expect(r.result.text).toBe(r.native.text);
  expect(r.retained.some(a => a.whisper?.text === candidate && a.deliveryText === r.native.text)).toBe(true);
  expect(r.logs.some(l => l.includes("repeated-six-gram"))).toBe(true);
});

test("a rejected repair keeps a separate accepted insertion and all native characters", async () => {
  const r = await repair("one two three four five six ".repeat(12), "multi");
  expect(r.clips).toHaveLength(2);
  expect(r.result.text).toBe(r.native.text.replace("survive another", "survive recovered clause another"));
  expect(r.logs.some(l => l.includes('"accepted":true'))).toBe(true);
  expect(r.logs.some(l => l.includes('"reason":"repeated-six-gram"'))).toBe(true);
});

test("polish rejection logs its reason and latency without transcript text", async () => {
  const candidate = "I will delete any words.";
  const server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: request => request.method === "GET"
    ? Response.json({ data: [] }) : Response.json({ choices: [{ message: { content: candidate } }] }) });
  const logs = spyOn(console, "error").mockImplementation(() => {});
  try {
    const result = await finalizeTranscriptionResultForSurface("I will not delete any words", "dictation", {
      ...process.env, QA_VOICE_STT_POLISH: "on", QA_VOICE_STT_CORRECTIONS: "off",
      QA_VOICE_STT_POLISH_ENDPOINT: `http://127.0.0.1:${server.port}/v1/chat/completions`,
      QA_VOICE_STT_POLISH_LOG_PATH: testTmp("span-polish.jsonl"),
    });
    expect(result.polishStatus).toBe("rejected");
    const log = logs.mock.calls.map(c => c.join(" ")).join(" ");
    expect(log).toContain('"event":"polish_rejected"');
    expect(log).toContain(result.polishReason ?? "missing-rejection-reason");
    expect(log).toContain('"latency_ms"');
    expect(log).not.toContain(candidate);
  } finally { logs.mockRestore(); server.stop(true); }
});

test("a looping alternate cannot authorize delivery of native words from the wrong input", async () => {
  await expect(repair("one two three four five six ".repeat(12), "identity")).rejects.toThrow("UNRESOLVED_FALLBACK_INCOMPLETE");
});
