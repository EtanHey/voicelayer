/**
 * voice_ask_results reports an Ask that is still open (lane c7, o6). Real handleVoiceAsk and handleVoiceAskResults;
 * TTS and the recorder are latch-driven mocks (no microphone, no audio), paths isolated by the preload. Synthetic text.
 */
import { afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "fs";
import { join } from "path";
import * as handlers from "../handlers";
import * as tts from "../tts";
import * as input from "../input";
import * as booking from "../session-booking";
import * as recording from "../recording-state";
import * as socket from "../socket-client";

const QUESTION = "Synthetic open question 👋 ".repeat(5); // 130 code points, 135 UTF-16 units.
const ANSWER = "Synthetic answer fu… no, full.";
const id = (n: number) => `2026-01-02T03-04-05-${String(n).padStart(3, "0")}Z-abcdef0${n}`;
let root: string, saved: string | undefined, logs: string[];
const spies: { mockRestore(): void }[] = [];

beforeEach(() => {
  if (process.env.VOICELAYER_TEST_ISOLATED !== "1") throw new Error("isolated preload required");
  saved = process.env.QA_VOICE_RECORDINGS_DIR;
  root = mkdtempSync(join(saved!, "open-ask-"));
  process.env.QA_VOICE_RECORDINGS_DIR = root;
  logs = [];
  spies.push(
    spyOn(console, "error").mockImplementation((...args: unknown[]) => { logs.push(args.map(String).join(" ")); }),
    spyOn(recording, "getEffectiveRecordingState").mockReturnValue("idle"),
    spyOn(input, "clearInput").mockImplementation(() => {}),
    spyOn(booking, "clearStopSignal").mockImplementation(() => {}),
    spyOn(tts, "awaitCurrentPlayback").mockResolvedValue(undefined),
    spyOn(socket, "isConnected").mockReturnValue(true),
    spyOn(socket, "broadcast").mockImplementation(() => {}),
  );
});
afterEach(() => {
  for (const spy of spies.splice(0).reverse()) spy.mockRestore();
  process.env.QA_VOICE_RECORDINGS_DIR = saved;
  rmSync(root, { recursive: true, force: true });
  // No answer or question text reaches any log line.
  expect(logs.filter(line => line.includes("Synthetic"))).toEqual([]);
});

/** An unanswered archive folder, as the recorder allocates it before transcription. */
function archive(n: number): string {
  const dir = join(root, "2026-01-02", id(n));
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "metadata.json"), JSON.stringify({ id: id(n), source: "voice_ask",
    created_at: `2026-01-02T03:04:05.00${n}Z`, transcription_status: "captured" }));
  writeFileSync(join(dir, "agent-transcript.txt"), QUESTION);
  return dir;
}
async function status(args: Record<string, unknown> = {}) {
  const result = await handlers.handleVoiceAskResults(args);
  expect(result.isError).not.toBe(true);
  return JSON.parse(result.content[0].text);
}
const latch = <T = void>() => Promise.withResolvers<T>();

/** A latched Ask: each step waits for the test to release it. */
function latchedAsk(end: "answer" | "away" | "no-input" | "error" | "prompt-error", n = 1) {
  const spoken = latch(), speakDone = latch(), listening = latch(), allocate = latch(), allocated = latch();
  const transcribe = latch(), transcribing = latch(), finish = latch();
  booked(true);
  spies.push(spyOn(tts, "speak").mockImplementation(async text => {
    spoken.resolve();
    await speakDone.promise;
    if (end === "prompt-error") throw new Error("Synthetic synthesis failure");
    return { playbackId: "synthetic", displayText: text, engine: "edge-tts" as const, voice: "synthetic",
      audioArtifact: { bytes: new Uint8Array([73, 68, 51]), format: "mp3" as const } };
  }));
  spies.push(spyOn(input, "waitForInput").mockImplementation(async (_timeout, _silence, _ptt, options) => {
    listening.resolve();
    await allocate.promise;
    options?.onArchiveCreated?.(archive(n));
    allocated.resolve();
    await transcribe.promise;
    options?.onPhaseChange?.("transcribing");
    transcribing.resolve();
    await finish.promise;
    if (end === "error") throw new Error("Synthetic STT failure");
    if (end === "away") { options?.onNoAnswer?.(false); return null; }
    if (end === "no-input") return null;
    return ANSWER;
  }));
  return { spoken, speakDone, listening, allocate, allocated, transcribe, transcribing, finish };
}
function booked(ownedByUs: boolean) {
  spies.push(spyOn(booking, "isVoiceBooked").mockReturnValue(ownedByUs ? { booked: true, ownedByUs: true }
    : { booked: true, ownedByUs: false, owner: { sessionId: "other", pid: 1, startedAt: "2026-01-02T03:04:05Z" } } as never));
}

test("an open ask is visible while speaking, listening and transcribing, then gone once answered", async () => {
  const ask = latchedAsk("answer");
  const pending = handlers.handleVoiceAsk({ message: QUESTION });
  const preview = Array.from(QUESTION).slice(0, 80).join("");

  await ask.spoken.promise;
  let page = await status();
  expect(page.results).toEqual([]);
  expect(page.open).toHaveLength(1);
  expect(page.open[0]).toEqual({ phase: "speaking", started_at: expect.any(String), question_preview: preview });
  expect(Number.isFinite(Date.parse(page.open[0].started_at))).toBe(true);
  expect(Array.from(page.open[0].question_preview)).toHaveLength(80);
  expect(page.message).toContain("Do not ask the user again");
  expect(page.message).toContain("voice_ask_results");

  ask.speakDone.resolve();
  await ask.listening.promise;
  page = await status();
  expect(page.open.map((ask: any) => ask.phase)).toEqual(["listening"]);
  expect(page.open[0].archive_id).toBeUndefined();

  ask.allocate.resolve();
  await ask.allocated.promise;
  page = await status();
  expect(page.open[0]).toMatchObject({ phase: "listening", archive_id: id(1), question_preview: preview });
  // The unanswered folder is the open ask, not a retained answer needing retranscription.
  expect(page.results).toEqual([]);

  ask.transcribe.resolve();
  await ask.transcribing.promise;
  page = await status();
  expect(page.open[0]).toMatchObject({ phase: "transcribing", archive_id: id(1) });

  // An archive_id lookup while open says so, never "No Ask answer exists".
  const lookup = await status({ archive_id: id(1) });
  expect(lookup.results).toEqual([]);
  expect(lookup.open).toEqual([page.open[0]]);
  expect(lookup.message).toContain("still open");
  expect(lookup.message).not.toContain("No Ask answer");
  // Another ID is unaffected by the open ask.
  expect(await status({ archive_id: id(9) })).toEqual({ results: [], message: "No Ask answer exists for this archive ID." });

  ask.finish.resolve();
  const result = await pending;
  expect(result.isError).not.toBe(true);
  page = await status();
  expect(page.open).toBeUndefined();
  expect(page.message).toBeUndefined();
});

for (const end of ["away", "no-input", "error", "prompt-error"] as const) {
  test(`the open record goes away when the ask ends: ${end}`, async () => {
    const ask = latchedAsk(end);
    const pending = handlers.handleVoiceAsk({ message: QUESTION });
    await ask.spoken.promise;
    expect((await status()).open).toHaveLength(1);
    ask.speakDone.resolve();
    if (end !== "prompt-error") {
      await ask.listening.promise;
      ask.allocate.resolve(); ask.transcribe.resolve();
      await ask.transcribing.promise;
      expect((await status()).open[0].phase).toBe("transcribing");
      ask.finish.resolve();
    }
    await pending;
    const page = await status();
    expect(page.open).toBeUndefined();
    expect(page.message).toBeUndefined();
  });
}

test("refused asks never show as open", async () => {
  const seen: unknown[] = [];
  const sample = () => { void handlers.handleVoiceAskResults({}).then(r => seen.push(JSON.parse(r.content[0].text).open)); };
  const speak = spyOn(tts, "speak").mockImplementation(async () => { throw new Error("refusal reached the prompt"); });
  spies.push(speak);

  // Invalid input.
  expect((await handlers.handleVoiceAsk({})).isError).toBe(true);
  // Prompt over its length contract.
  expect((await handlers.handleVoiceAsk({ message: "Synthetic long. ".repeat(400) })).isError).toBe(true);
  // Another session holds the microphone booking; sample the registry while the refusal is being decided.
  const busy = spyOn(booking, "isVoiceBooked").mockImplementation(() => {
    sample();
    return { booked: true, ownedByUs: false, owner: { sessionId: "other", pid: 1, startedAt: "x" } } as never;
  });
  spies.push(busy);
  expect((await handlers.handleVoiceAsk({ message: "Synthetic busy?" })).content[0].text).toContain("other");
  busy.mockRestore();
  // Capture is owned by another ask or dictation.
  booked(true);
  const owned = spyOn(tts, "isCaptureAdmissionReserved").mockImplementation(() => { sample(); return true; });
  spies.push(owned);
  await handlers.handleVoiceAsk({ message: "Synthetic owned?" });
  owned.mockRestore();

  expect(speak).not.toHaveBeenCalled();
  await Promise.resolve();
  expect(seen.length).toBeGreaterThanOrEqual(2);
  expect(seen.every(open => open === undefined)).toBe(true);
  expect((await status()).open).toBeUndefined();
});

test("a retained answer replaces its open row; the tool stays read-only", async () => {
  const ask = latchedAsk("answer");
  const pending = handlers.handleVoiceAsk({ message: QUESTION });
  await ask.spoken.promise;
  ask.speakDone.resolve();
  await ask.listening.promise;
  ask.allocate.resolve();
  await ask.allocated.promise;
  // The answer is on disk before the flow has finished: report it as answered, not as open.
  writeFileSync(join(root, "2026-01-02", id(1), "voicelayer-transcript.txt"), ANSWER);
  const page = await status();
  expect(page.open).toBeUndefined();
  expect(page.results.map((r: any) => [r.id, r.status, r.answer])).toEqual([[id(1), "answered", ANSWER]]);
  ask.transcribe.resolve(); ask.finish.resolve();
  await pending;
  const { getToolDefinitions } = await import("../mcp-tools");
  const tool = getToolDefinitions().find(t => t.name === "voice_ask_results");
  expect(tool?.annotations?.readOnlyHint).toBe(true);
  expect(tool?.description).toContain("open");
});
