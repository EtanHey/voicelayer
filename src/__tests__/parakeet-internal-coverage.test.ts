/**
 * V34 (2.2.62): internal-window speech coverage through the REAL ParakeetBackend
 * request path. The decoder, VAD and clock are injected with numeric fixtures:
 * synthetic tone PCM on disk, synthetic token times, synthetic Silero windows.
 * No playback, capture, audio generation for listening, or model inference.
 *
 * This file imports only modules that existed before the fix, so it runs
 * (and fails) against the pre-fix backend too.
 */
import { beforeEach, describe, expect, test } from "bun:test";
import { mkdirSync, readFileSync, writeFileSync } from "fs";
import { createHash } from "crypto";
import { join } from "path";
import { testTmp } from "./setup/test-tmp";
import { ParakeetBackend } from "../parakeet-backend";
import type { ParakeetResponse } from "../parakeet-server";
import { ParakeetServiceError } from "../parakeet-server";
import type { ParakeetFallbackAttempt } from "../parakeet-attempts";
import type { ParakeetSpeechEvidence } from "../parakeet-vad";
import { VAD_CHUNK_SAMPLES } from "../vad-constants";
import type { STTBackend, STTResult } from "../stt";

const RATE = 16000, SECONDS = 70, FRAMES = SECONDS * RATE;
const root = testTmp("v34-internal-coverage"), path = join(root, "take.wav");

/** File-only synthetic tone so the WAV is non-zero; nothing is played or heard. */
function wav(): Buffer {
  const b = Buffer.alloc(44 + FRAMES * 2);
  b.write("RIFF"); b.writeUInt32LE(b.length - 8, 4); b.write("WAVEfmt ", 8);
  b.writeUInt32LE(16, 16); b.writeUInt16LE(1, 20); b.writeUInt16LE(1, 22);
  b.writeUInt32LE(RATE, 24); b.writeUInt32LE(RATE * 2, 28); b.writeUInt16LE(2, 32); b.writeUInt16LE(16, 34);
  b.write("data", 36); b.writeUInt32LE(FRAMES * 2, 40);
  for (let i = 0; i < FRAMES; i++) b.writeInt16LE(Math.round(3000 * Math.sin(i * 2 * Math.PI * 200 / RATE)), 44 + i * 2);
  return b;
}

interface Word { text: string; start: number; end: number }
/** One synthetic word every 0.5 s; `skip` drops the words a window lost. */
function words(until: number, skip?: (start: number) => boolean): Word[] {
  const out: Word[] = [];
  for (let i = 0; i * 0.5 + 0.3 <= until; i++) {
    const start = i * 0.5;
    if (skip?.(start)) continue;
    // A naturally repeated word pair ("the the") and a negation inside the
    // region the primary windowing loses.
    const text = start === 10 || start === 10.5 ? "the" : start === 26 ? "not" : `w${i}`;
    out.push({ text, start, end: start + 0.3 });
  }
  return out;
}
function response(ws: Word[], windowEndFrames: number[] | undefined, geometry?: [number, number]): ParakeetResponse {
  const r: ParakeetResponse & Record<string, unknown> = {
    text: ws.map(w => w.text).join(" "), complete: true, input_frames: FRAMES, covered_frames: FRAMES, sample_rate: RATE,
    last_token_end_s: ws.length ? Math.max(...ws.map(w => w.end)) : null, inference_s: 0.1, language: null,
    raw_token_times: ws.map(w => ({ start: w.start, end: w.end })),
    attemptEvidence: { status: "RETURNED", decodeCoverage: "FULL_INPUT", tail: "UNKNOWN", timesValid: true },
  };
  if (windowEndFrames) r.window_end_frames = windowEndFrames;
  if (geometry) r.window_geometry = { chunk_seconds: geometry[0], overlap_seconds: geometry[1] };
  return r;
}
// Primary geometry 30 s / 2 s over 70 s: windows end at 30 s, 58 s, 70 s.
const PRIMARY_ENDS = [30 * RATE, 58 * RATE, FRAMES];
// The internal window ending at 30 s lost every word in [25.0, 29.5).
const lostNearInternalEnd = (start: number) => start >= 25 && start < 29.5;
const primaryUncovered = () => response(words(69.3, lostNearInternalEnd), PRIMARY_ENDS, [30, 2]);
const primaryComplete = () => response(words(69.3), PRIMARY_ENDS, [30, 2]);
// A 60 s / 15 s retry over 70 s: windows end at 60 s, 70 s.
const retryCovered = () => response(words(69.3), [60 * RATE, FRAMES], [60, 15]);

/** Synthetic Silero windows bound to the exact snapshot bytes the backend submits. */
function vad(snapshot: string, speech: (seconds: number) => boolean, status: "COMPLETE" | "UNKNOWN" = "COMPLETE"): ParakeetSpeechEvidence {
  const bytes = readFileSync(snapshot);
  const probabilities = Array.from({ length: Math.ceil(FRAMES / VAD_CHUNK_SAMPLES) }, (_, i) => speech(i * VAD_CHUNK_SAMPLES / RATE) ? 0.9 : 0.02);
  return { status, threshold: 0.3, inputSha256: createHash("sha256").update(bytes).digest("hex"), frames: FRAMES, analyzedFrames: FRAMES,
    probabilities, maxProbability: 0.9, speechFrames: probabilities.filter(p => p >= 0.3).length * VAD_CHUNK_SAMPLES };
}
const speechThroughout = (s: number) => s < 69.4;

interface Harness {
  backend: ParakeetBackend; events: string[]; decodes: { options: unknown }[]; retained: ParakeetFallbackAttempt[]; whisperCalls: () => number;
}
function harness(opts: {
  decodes: ((options: unknown) => ParakeetResponse | Promise<ParakeetResponse>)[];
  speech?: (s: number) => boolean; vadStatus?: "COMPLETE" | "UNKNOWN"; clock?: number[];
}): Harness {
  const events: string[] = [], decodes: { options: unknown }[] = [], retained: ParakeetFallbackAttempt[] = [];
  let whisper = 0;
  const fallbackBackend: STTBackend = { name: "whisper-fixture", isAvailable: async () => true,
    transcribe: async () => { whisper++; events.push("whisper"); return { text: "whisper fallback words", backend: "whisper-fixture", durationMs: 1,
      attemptEvidence: { status: "RETURNED", decodeCoverage: "FULL_INPUT", tail: "VERIFIED_BY_EXTERNAL_EVIDENCE", timesValid: true } }; } };
  const clock = opts.clock ? [...opts.clock] : undefined;
  const backend = new ParakeetBackend({ fallbackBackend, unload: async () => {}, env: () => ({ QA_VOICE_WHISPER_LANG: "en" }),
    transcribe: async (_path: string, options?: unknown) => {
      decodes.push({ options }); events.push(`decode:${decodes.length}`);
      const next = opts.decodes[decodes.length - 1];
      if (!next) throw new Error(`unexpected decode #${decodes.length}`);
      return next(options);
    },
    speechProbe: async snapshot => { events.push("probe"); return vad(snapshot, opts.speech ?? speechThroughout, opts.vadStatus); },
    retainFallback: attempt => { retained.push(attempt); events.push(`retain:${attempt.stage}`); return `receipt-${retained.length}`; },
    ...(clock ? { now: () => clock.length > 1 ? clock.shift()! : clock[0]! } : {}),
  } as ConstructorParameters<typeof ParakeetBackend>[0]);
  return { backend, events, decodes, retained, whisperCalls: () => whisper };
}
type Coverage = { status: string; reason?: string; retries: number; maxRetries: number; attempts: { attempt: number; status: string; geometry: unknown; windowEndFrames: unknown; gaps: { afterTokenEndS: number; beforeTokenStartS: number; windowEndS: number | null; speechS?: number }[] }[]; elapsedMsAtRetry?: number; requiredMs?: number; budgetMs?: number };
const coverage = (r: STTResult) => (r as STTResult & { internalCoverage?: Coverage }).internalCoverage;

beforeEach(() => { mkdirSync(root, { recursive: true }); writeFileSync(path, wav()); });

describe("V34 internal-window speech coverage (production ParakeetBackend path)", () => {
  test("FAIL-FIRST: an internal window whose last token ends before ongoing speech triggers ONE wider-context retry", async () => {
    const h = harness({ decodes: [primaryUncovered, retryCovered] });
    const result = await h.backend.transcribe(path);

    expect(h.decodes.length).toBe(2);
    expect(h.decodes[0]!.options).toBeUndefined(); // primary request is unchanged
    expect(h.decodes[1]!.options).toMatchObject({ geometry: { chunkSeconds: 60, overlapSeconds: 15 } });
    expect(result.text).toBe(retryCovered().text);
    expect(result.text).toContain(" not ");
    expect(result.backend).toBe("parakeet-resident+internal-coverage-retry");
    expect(result.outcome).toBe("NATIVE_NONEMPTY_COMPLETENESS_UNKNOWN");
    expect(h.whisperCalls()).toBe(0);
    // Raw primary is committed BEFORE the retry runs; terminal record after.
    expect(h.events).toEqual(["decode:1", "probe", "retain:internal-coverage-boundary", "decode:2", "retain:internal-coverage-terminal"]);
    const [boundary, terminal] = h.retained;
    expect((boundary!.parakeet as ParakeetResponse).text).toBe(primaryUncovered().text);
    expect((terminal!.parakeet as ParakeetResponse).text).toBe(primaryUncovered().text);
    expect((terminal!.retryAttempt as ParakeetResponse).text).toBe(retryCovered().text);
    expect(terminal!.deliveryText).toBe(retryCovered().text);
    expect(result.fallbackEvidencePath).toBe("receipt-2");
    const c = coverage(result)!;
    expect(c.status).toBe("RETRY_COVERED");
    expect(c.retries).toBe(1); expect(c.maxRetries).toBe(1);
    expect(c.attempts.map(a => [a.attempt, a.status])).toEqual([[1, "UNCOVERED"], [2, "COVERED"]]);
    expect(c.attempts[0]!.windowEndFrames).toEqual(PRIMARY_ENDS);
    expect(c.attempts[1]!.windowEndFrames).toEqual([60 * RATE, FRAMES]);
    const gap = c.attempts[0]!.gaps[0]!;
    expect(gap.afterTokenEndS).toBeCloseTo(24.8, 5); expect(gap.beforeTokenStartS).toBeCloseTo(29.5, 5);
    expect(gap.windowEndS).toBe(30); expect(gap.speechS!).toBeGreaterThan(4);
  });

  test("control: complete coverage → no VAD probe, no retry, primary text", async () => {
    const h = harness({ decodes: [primaryComplete] });
    const result = await h.backend.transcribe(path);
    expect(h.events).toEqual(["decode:1"]);
    expect(result.text).toBe(primaryComplete().text);
    expect(result.backend).toBe("parakeet-resident");
    expect(result.outcome).toBe("NATIVE_NONEMPTY_COMPLETENESS_UNKNOWN");
    expect(coverage(result)?.status).toBe("COVERED");
  });

  test("control: silence-only remainder after the internal window's last token → no retry", async () => {
    const h = harness({ decodes: [primaryUncovered], speech: s => s < 69.4 && !(s >= 24.8 && s < 29.5) });
    const result = await h.backend.transcribe(path);
    expect(h.events).toEqual(["decode:1", "probe"]);
    expect(result.text).toBe(primaryUncovered().text);
    expect(coverage(result)?.status).toBe("COVERED");
    expect(h.retained).toEqual([]);
  });

  test("control: final-tail behaviour unchanged — uncovered tail still goes to the existing Whisper fallback, no internal retry", async () => {
    const tailLost = () => response(words(40), PRIMARY_ENDS, [30, 2]);
    const h = harness({ decodes: [tailLost] });
    const result = await h.backend.transcribe(path);
    expect(h.decodes.length).toBe(1);
    expect(h.whisperCalls()).toBe(1);
    expect(result.backend).toContain("+fallback-uncovered-tail->whisper-fixture");
    expect(coverage(result)).toBeUndefined();
  });

  test("control: a short trailing gap in the FINAL window is not an internal-window retry", async () => {
    const h = harness({ decodes: [() => response(words(67), PRIMARY_ENDS, [30, 2])] });
    const result = await h.backend.transcribe(path);
    expect(h.decodes.length).toBe(1); expect(h.whisperCalls()).toBe(0);
    expect(coverage(result)?.status).toBe("COVERED");
  });

  test("control: missing token timestamps → uncertainty exposed, no retry, words kept", async () => {
    const noTimes = () => { const r = primaryUncovered(); delete r.raw_token_times; return r; };
    const h = harness({ decodes: [noTimes] });
    const result = await h.backend.transcribe(path);
    expect(h.decodes.length).toBe(1);
    expect(result.text).toBe(primaryUncovered().text);
    expect(coverage(result)).toMatchObject({ status: "UNKNOWN", reason: "missing-token-times", retries: 0 });
  });

  test("control: missing window boundaries (older worker) → uncertainty exposed, no retry", async () => {
    const h = harness({ decodes: [() => response(words(69.3, lostNearInternalEnd), undefined)] });
    const result = await h.backend.transcribe(path);
    expect(h.decodes.length).toBe(1);
    expect(coverage(result)).toMatchObject({ status: "UNKNOWN", reason: "missing-window-boundaries" });
  });

  test("control: VAD evidence unavailable → uncertainty exposed, no retry, words kept", async () => {
    const h = harness({ decodes: [primaryUncovered], vadStatus: "UNKNOWN" });
    const result = await h.backend.transcribe(path);
    expect(h.decodes.length).toBe(1);
    expect(result.text).toBe(primaryUncovered().text);
    expect(coverage(result)).toMatchObject({ status: "UNKNOWN", reason: "speech-evidence-unavailable" });
  });

  test("control: request budget exhausted → no retry, deadline not reset, primary delivered flagged", async () => {
    // Primary started at t=0 and returned at t=100 s of the shared 120 s budget.
    const h = harness({ decodes: [primaryUncovered], clock: [0, 100_000] });
    const result = await h.backend.transcribe(path);
    expect(h.decodes.length).toBe(1);
    expect(result.text).toBe(primaryUncovered().text);
    expect(result.outcome).toBe("NATIVE_NONEMPTY_INTERNAL_SPEECH_UNCOVERED");
    expect(result.backend).toBe("parakeet-resident+internal-coverage-uncertain");
    expect(coverage(result)).toMatchObject({ status: "UNCOVERED_BUDGET_EXHAUSTED", retries: 0, budgetMs: 120_000, elapsedMsAtRetry: 100_000, requiredMs: 150_000 });
    expect(h.retained.map(r => r.stage)).toEqual(["internal-coverage-boundary", "internal-coverage-terminal"]);
  });

  test("control: retry gets only the REMAINING budget, and a retry timeout keeps the primary words", async () => {
    const h = harness({ clock: [0, 30_000], decodes: [primaryUncovered,
      () => { throw new ParakeetServiceError("TIMEOUT", { partial_stdout: "{\"text\":" }, "Parakeet request timeout"); }] });
    const result = await h.backend.transcribe(path);
    expect(h.decodes.length).toBe(2);
    expect(h.decodes[1]!.options).toMatchObject({ timeoutMs: 90_000 });
    expect(result.text).toBe(primaryUncovered().text);
    expect(result.outcome).toBe("NATIVE_NONEMPTY_INTERNAL_SPEECH_UNCOVERED");
    expect(coverage(result)).toMatchObject({ status: "UNCOVERED_RETRY_FAILED", reason: "TIMEOUT", retries: 1 });
    expect(h.retained.at(-1)!.retryAttempt).toEqual({ partial_stdout: "{\"text\":" });
    expect(h.whisperCalls()).toBe(0);
  });

  test("control: retried hypothesis still partial → primary kept, retry retained, no second retry", async () => {
    const stillLost = () => response(words(69.3, s => s >= 25.5 && s < 28), [60 * RATE, FRAMES], [60, 15]);
    const h = harness({ decodes: [primaryUncovered, stillLost] });
    const result = await h.backend.transcribe(path);
    expect(h.decodes.length).toBe(2);
    expect(result.text).toBe(primaryUncovered().text);
    expect(result.outcome).toBe("NATIVE_NONEMPTY_INTERNAL_SPEECH_UNCOVERED");
    const c = coverage(result)!;
    expect(c).toMatchObject({ status: "UNCOVERED_RETRY_PARTIAL", reason: "retry-still-uncovered", retries: 1, maxRetries: 1 });
    expect(c.attempts[1]!.gaps.length).toBe(1);
    expect((h.retained.at(-1)!.retryAttempt as ParakeetResponse).text).toBe(stillLost().text);
  });

  test("control: naturally repeated words are conserved verbatim in the delivered hypothesis", async () => {
    const h = harness({ decodes: [primaryUncovered, retryCovered] });
    const result = await h.backend.transcribe(path);
    expect(result.text).toContain(" the the ");
    expect(result.text.split(" ").length).toBe(retryCovered().raw_token_times!.length);
    expect((h.retained[0]!.parakeet as ParakeetResponse).text).toContain(" the the ");
  });
});
