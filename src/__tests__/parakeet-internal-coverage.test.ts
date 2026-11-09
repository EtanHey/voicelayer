import { expect, test } from "bun:test";
import { createHash } from "crypto";
import { readFileSync, writeFileSync } from "fs";
import { join } from "path";
import { ParakeetBackend } from "../parakeet-backend";
import type { ParakeetResponse } from "../parakeet-server";
import type { ParakeetSpeechEvidence } from "../parakeet-vad";
import { privateCorpusPaths } from "./setup/private-specimens";
import { testTmp } from "./setup/test-tmp";

async function replay(path: string, native: ParakeetResponse, speech: ParakeetSpeechEvidence, recovered: string) {
  let retries = 0;
  const router = new ParakeetBackend({
    transcribe: async () => native, speechProbe: async () => speech,
    unload: async () => {}, retainFallback: () => "isolated-evidence",
    env: () => ({ QA_VOICE_WHISPER_LANG: "en" }),
    fallbackBackend: { name: "retained-whisper-decode", isAvailable: async () => true, transcribe: async snapshot => {
      expect(readFileSync(snapshot)).toEqual(readFileSync(path)); // No cropping or rewriting.
      retries++; return { text: recovered, backend: "retained-whisper-decode", durationMs: 0 };
    } },
  });
  return { result: await router.transcribe(path), retries };
}

const privatePaths = privateCorpusPaths("parakeet-internal-coverage");
test.skipIf(!privatePaths)("V32: legacy untimed tokens retain native text instead of a whole-take replacement", async () => {
  const root = privatePaths!.recordings;
  const native: ParakeetResponse = JSON.parse(readFileSync(join(root, "native.json"), "utf8"));
  const speech: ParakeetSpeechEvidence = JSON.parse(readFileSync(join(root, "speech.json"), "utf8"));
  const recovered = JSON.parse(readFileSync(join(root, "whisper.json"), "utf8")).transcription.map((s: { text: string }) => s.text.trim()).join(" ");
  const clause = readFileSync(join(root, "clause.txt"), "utf8").toLowerCase().replace(/[^a-z0-9 ]/g, "");
  expect(native.text.toLowerCase().replace(/[^a-z0-9 ]/g, "")).not.toContain(clause);
  expect(recovered.toLowerCase().replace(/[^a-z0-9 ]/g, "")).toContain(clause);
  const { result, retries } = await replay(join(root, "internal.wav"), native, speech, recovered);
  expect(retries).toBe(0);
  expect(result.backend).toContain("uncovered-internal");
  expect(result.text).toBe(native.text);
});

function fixture() {
  const frames = 60 * 16000, bytes = Buffer.alloc(44 + frames * 2);
  bytes.write("RIFF"); bytes.writeUInt32LE(bytes.length - 8, 4); bytes.write("WAVEfmt ", 8);
  bytes.writeUInt32LE(16, 16); bytes.writeUInt16LE(1, 20); bytes.writeUInt16LE(1, 22);
  bytes.writeUInt32LE(16000, 24); bytes.writeUInt32LE(32000, 28); bytes.writeUInt16LE(2, 32); bytes.writeUInt16LE(16, 34);
  bytes.write("data", 36); bytes.writeUInt32LE(frames * 2, 40); bytes.writeInt16LE(1, 44);
  const path = testTmp("internal-coverage.wav"); writeFileSync(path, bytes);
  // Sanitized V32 geometry: an early token, an unheard clause at 24.72-28.16,
  // then later tokens. Full frame coverage and a healthy tail hide the hole.
  const raw_token_times = [{ start: .72, end: 1.6 }, { start: 29, end: 60 }];
  const native: ParakeetResponse = { text: "Keep these earlier words and the final thought.", complete: true,
    input_frames: frames, covered_frames: frames, sample_rate: 16000, last_token_end_s: 60,
    inference_s: 0, language: null, raw_token_times };
  const speech: ParakeetSpeechEvidence = { status: "COMPLETE", threshold: .3,
    inputSha256: createHash("sha256").update(bytes).digest("hex"), frames, analyzedFrames: frames,
    probabilities: Array.from({ length: Math.ceil(frames / 512) }, (_, i) => i * .032 >= 24.72 && i * .032 < 28.16 ? .9 : .01) };
  return { path, native, speech };
}

test("legacy time-only internal evidence cannot authorize an unaligned replacement", async () => {
  const f = fixture(), recovered = "Keep these earlier words and fu… no, the complete final thought.";
  const r = await replay(f.path, f.native, f.speech, recovered);
  expect(r.retries).toBe(0); expect(r.result.text).toBe(f.native.text);
});

test.each(["silence", "wrong-hash", "partial", "invalid-probabilities", "covered", "missing-tokens", "invalid-tokens"])("%s cannot establish an internal omission", async mode => {
  const f = fixture();
  if (mode === "silence") f.speech.probabilities!.fill(.01);
  if (mode === "wrong-hash") f.speech.inputSha256 = "other-input";
  if (mode === "partial") f.speech.analyzedFrames = 512;
  if (mode === "invalid-probabilities") f.speech.probabilities![800] = NaN;
  if (mode === "covered") f.native.raw_token_times = [{ start: 0, end: 60 }];
  if (mode === "missing-tokens") delete f.native.raw_token_times;
  if (mode === "invalid-tokens") f.native.raw_token_times = [{ start: 50, end: 2 }];
  const r = await replay(f.path, f.native, f.speech, "must not replace words");
  expect(r.retries).toBe(0); expect(r.result.text).toBe(f.native.text);
});
