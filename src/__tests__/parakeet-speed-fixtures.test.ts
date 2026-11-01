/** SPEED's synthetic cases applied to the real adapter (not its fixture oracle).
 * No private audio paths/IDs/targets are copied or opened. Geometry is rebased
 * to a synthetic two-second PCM file; original fixture identity remains opaque.
 */
import { test, expect } from "bun:test";
import { mkdirSync, readFileSync, writeFileSync } from "fs";
import { createHash } from "crypto";
import fixtures from "./fixtures/parakeet-fallback-cases.json";
import { testTmp } from "./setup/test-tmp";
import { ParakeetBackend, STTQualificationError } from "../parakeet-backend";
import { ParakeetServiceError, type ParakeetResponse } from "../parakeet-server";
import type { STTAttemptEvidence } from "../soundlayer/contracts";
import type { ParakeetFallbackAttempt } from "../parakeet-attempts";

function wav(complete: boolean): Buffer<ArrayBuffer> {
  const b = Buffer.alloc(64044);
  b.write("RIFF"); b.writeUInt32LE((complete ? b.length : b.length + 32000) - 8, 4); b.write("WAVEfmt ", 8);
  b.writeUInt32LE(16, 16); b.writeUInt16LE(1, 20); b.writeUInt16LE(1, 22);
  b.writeUInt32LE(16000, 24); b.writeUInt32LE(32000, 28); b.writeUInt16LE(2, 32); b.writeUInt16LE(16, 34);
  b.write("data", 36); b.writeUInt32LE(complete ? 64000 : 96000, 40);
  b.writeInt16LE(1000, 44); b.writeInt16LE(1000, b.length - 2); return b;
}
function evidence(a: Record<string, unknown>, hash: string): STTAttemptEvidence {
  return { status: a.status as STTAttemptEvidence["status"], processExitCode: a.process_exit as number,
    decodeCoverage: a.coverage === "PARTIAL_RETAINED_PCM" ? "PARTIAL" : "FULL_INPUT",
    tail: a.tail as STTAttemptEvidence["tail"], timesValid: a.times_valid as boolean, inputSha256: hash };
}

for (const f of fixtures.fixtures) test(`SPEED adapter boundary: ${f.id}`, async () => {
  const root = testTmp("speed-adapter-fixtures", f.id); mkdirSync(root, { recursive: true });
  const path = root + "/synthetic.wav", bytes = wav(f.capture_complete); writeFileSync(path, bytes);
  const hash = createHash("sha256").update(bytes).digest("hex");
  const ledger: ParakeetFallbackAttempt[] = []; let pCalls = 0, wCalls = 0;
  const expectsVad = f.native.status === "EMPTY_RESPONSE";
  const backend = new ParakeetBackend({ env: () => ({ QA_VOICE_WHISPER_LANG: "en" }), unload: async () => {},
    speechProbe: async () => ({ status: "UNKNOWN", threshold: 0.3, errorType: "FixtureVadUnavailable" }),
    retainFallback: value => { ledger.push(value); return "synthetic-attempt-" + ledger.length; },
    transcribe: async submitted => {
      pCalls++; expect(readFileSync(submitted)).toEqual(bytes);
      if (["ERROR", "TIMEOUT"].includes(f.native.status)) throw new ParakeetServiceError(f.native.status as "ERROR" | "TIMEOUT", f.native);
      return { text: f.native.text, complete: f.native.status !== "PARTIAL", input_frames: 32000,
        covered_frames: f.native.coverage === "PARTIAL_RETAINED_PCM" ? 16000 : 32000,
        sample_rate: 16000, inference_s: 0.01, last_token_end_s: 1.8, language: null,
        attemptEvidence: evidence(f.native, hash) } as ParakeetResponse;
    },
    fallbackBackend: { name: "whisper-fixture", isAvailable: async () => true, transcribe: async submitted => {
      wCalls++; expect(readFileSync(submitted)).toEqual(bytes);
      // The native/input boundary must already be durable before W starts.
      expect(ledger.map(row => row.stage)).toEqual(expectsVad ? ["native-or-input-boundary", "vad-boundary"] : ["native-or-input-boundary"]);
      if (expectsVad) expect(ledger[1].speechEvidence).toMatchObject({ status: "UNKNOWN", errorType: "FixtureVadUnavailable" });
      const w = f.whisper!;
      if (["ERROR", "TIMEOUT"].includes(w.status)) throw new STTQualificationError("UNRESOLVED_FALLBACK_FAILED", w);
      return { text: w.text, backend: "whisper-fixture", durationMs: 1,
        attemptEvidence: evidence(w, f.identity_mismatch ? "0".repeat(64) : hash) };
    } },
  });
  let terminal: string | undefined;
  try { terminal = (await backend.transcribe(path)).outcome; }
  catch (error) { if (error instanceof STTQualificationError) terminal = error.outcome; else throw error; }
  expect(terminal).toBe(f.expected.terminal); expect(wCalls).toBe(1);
  expect(pCalls).toBe(f.capture_complete ? 1 : 0);
  expect(ledger.length).toBe(expectsVad ? 3 : 2); expect<string | undefined>(ledger.at(-1)!.outcome).toBe(terminal);
  expect(ledger.at(-1)!.audioPath).toBe(path); expect(ledger.at(-1)!.inputSha256).toBe(hash);
  // A truncated container is refused before P: do not manufacture a model
  // attempt merely to match an abstract fixture's earlier native-partial stage.
  if (!f.capture_complete) expect(ledger[0].parakeet).toBeNull();
  expect(terminal).not.toBe("SUCCESS");
});
