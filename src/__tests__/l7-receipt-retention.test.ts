import { expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, symlinkSync, utimesSync, writeFileSync } from "fs";
import { dirname, join } from "path";
import { randomUUID } from "crypto";
import * as receipts from "../transcription-stage-receipt";
import { archiveVoiceBarUntranscribedRecording, createWavBuffer, finalizeTranscriptionResultForSurface } from "../input";

test("receipt writes keep only the newest five attempts without changing archived audio", async () => {
  const archive = archiveVoiceBarUntranscribedRecording({ audioBytes: createWavBuffer(new Uint8Array(3200)), source: "voicebar", silenceMode: "standard", pushToEnd: false, durationMs: 100, backend: "fixture", reason: "captured" });
  const audio = join(archive, "audio.wav"), before = readFileSync(audio);
  for (let i = 0; i < 7; i++) await finalizeTranscriptionResultForSurface(`Keep every spoken word attempt ${i}.`, null,
    { ...process.env, QA_VOICE_CORRECTOR: "identity" }, undefined, audio);
  expect(readdirSync(receipts.transcriptionStageReceiptDirectory(audio))).toHaveLength(5);
  expect(readFileSync(audio)).toEqual(before);
});

test("retention keeps at most 500 attempts and 30 days, oldest first, only inside its store", () => {
  const root = mkdtempSync(join(process.env.VOICELAYER_TEST_RUN_ROOT!, "retention-"));
  const store = join(root, "transcription-stages"), now = Date.UTC(2026, 10, 11);
  const files: string[] = [];
  for (let i = 0; i < 507; i++) {
    const attempt = randomUUID(), id = `2026-11-11T00-00-00-000Z-${i.toString(16).padStart(8, "0")}`;
    const path = join(store, "2026-11-11", id, `stt-stages-${attempt}.json`);
    mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
    writeFileSync(path, JSON.stringify({ schema_version: 1, attempt_id: attempt, created_at: new Date(i < 2 ? now - 31 * 86400000 : now - (507 - i) * 1000).toISOString() }), { mode: 0o600 });
    files.push(path);
  }
  const audio = join(root, "recordings", "audio.wav"); mkdirSync(dirname(audio)); writeFileSync(audio, "archive never pruned");
  const debug = join(store, "debug.json"); writeFileSync(debug, "unknown file never pruned");
  (receipts as any).pruneTranscriptionStageReceipts(store, now);
  expect(files.filter(existsSync)).toHaveLength(500);
  expect(files.slice(0, 7).some(existsSync)).toBe(false);
  expect(files.slice(7).every(existsSync)).toBe(true);
  expect(readFileSync(audio, "utf8")).toBe("archive never pruned");
  expect(readFileSync(debug, "utf8")).toBe("unknown file never pruned");
});

test("retention never follows a store alias into an external directory", () => {
  const root = mkdtempSync(join(process.env.VOICELAYER_TEST_RUN_ROOT!, "retention-alias-"));
  const outside = join(root, "outside"), alias = join(root, "transcription-stages");
  mkdirSync(outside); const victim = join(outside, "keep.json"); writeFileSync(victim, "keep"); symlinkSync(outside, alias);
  (receipts as any).pruneTranscriptionStageReceipts(alias);
  expect(readFileSync(victim, "utf8")).toBe("keep");
});

test("same-millisecond attempts keep the newest writes rather than UUID order", () => {
  const store = mkdtempSync(join(process.env.VOICELAYER_TEST_RUN_ROOT!, "retention-tie-"));
  const take = join(store, "2026-11-11", "2026-11-11T00-00-00-000Z-1234abcd");
  mkdirSync(take, { recursive: true, mode: 0o700 });
  const now = Date.UTC(2026, 10, 11), files: string[] = [];
  for (let i = 0; i < 7; i++) {
    const attempt = `00000000-0000-4000-8000-${(7 - i).toString().padStart(12, "0")}`;
    const path = join(take, `stt-stages-${attempt}.json`);
    writeFileSync(path, JSON.stringify({ schema_version: 1, attempt_id: attempt, created_at: new Date(now).toISOString() }), { mode: 0o600 });
    utimesSync(path, (now + i) / 1000, (now + i) / 1000); files.push(path);
  }
  receipts.pruneTranscriptionStageReceipts(store, now);
  expect(files.map(existsSync)).toEqual([false, false, true, true, true, true, true]);
});
