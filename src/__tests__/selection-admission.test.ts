import { afterEach, expect, spyOn, test } from "bun:test";
import { readFileSync } from "node:fs";
import * as ingress from "../speak-archive";
import { join } from "node:path";
import { parseCommand } from "../socket-protocol";
import { z } from "zod";
import { selectionIdentity } from "../speech-identity";
import * as tts from "../tts";
import * as input from "../input";
import * as client from "../socket-client";
import * as archive from "../speech-archive-live";
import { handleSocketCommand, resetSelectionReadQueueForTests } from "../socket-handlers";

const spies: { mockRestore(): void }[] = [];
afterEach(() => { resetSelectionReadQueueForTests(); for (const spy of spies.splice(0)) spy.mockRestore(); });

test("selection admission preserves unrelated reads and never emits QUEUE_CLEARED", async () => {
  const started: string[] = [];
  const counts: number[] = [];
  spies.push(spyOn(input, "getRecordingState").mockReturnValue("idle"),
    spyOn(input, "getEffectiveRecordingState").mockReturnValue("idle"),
    spyOn(tts, "prepareSelectionReadStart").mockImplementation(() => new Promise(() => {})),
    spyOn(tts, "speakText").mockImplementation((text) => {
      started.push(text);
      return { id: text, generation: 1, done: Promise.resolve(), playerExited: Promise.resolve(),
        started: Promise.resolve({}), completion: Promise.resolve({}) };
    }), spyOn(client, "broadcast").mockImplementation(event => { if (event.type === "read_queue") counts.push(event.count); }));
  const cleared = spyOn(archive, "cancelQueuedSpeech");
  spies.push(cleared);
  let id = 0;
  const press = (text: string) => handleSocketCommand({ cmd: "speak_text", id: `q1-${++id}`, text,
    source: "selection", format: "markdown", queue: true });
  await press("Alpha"); await press("Bravo"); await press("Charlie");
  for (const text of ["Charlie", "* [ ] Bravo", "2. Charlie"]) {
    expect(await press(text)).toMatchObject({ outcome: "noop", reason: "Already queued" });
  }
  expect(await handleSocketCommand({ cmd: "speak_text", text: "Bravo", source: "selection" })).toMatchObject({ outcome: "noop", reason: "Already queued" });
  expect(counts.at(-1)).toBe(2);
  expect(await press("1. Alpha")).toMatchObject({ outcome: "accept" });
  expect(started).toEqual(["Alpha", "Bravo"]);
  expect(counts.at(-1)).toBe(1);
  expect(cleared).not.toHaveBeenCalled();
  await handleSocketCommand({ cmd: "read_next", request_id: "q1-1" });
  expect(started).toEqual(["Alpha", "Bravo"]);
  await handleSocketCommand({ cmd: "stop" });
  expect(counts.at(-1)).toBe(0);
  expect(cleared).toHaveBeenCalledTimes(1);
  const path = process.env.VOICELAYER_ADMISSION_WIRE;
  if (path) {
    resetSelectionReadQueueForTests(); cleared.mockClear(); started.length = 0;
    const receipts: ingress.SpeakArchiveContext[] = [];
    const create = ingress.createSpeakReceipt;
    spies.push(spyOn(ingress, "createSpeakReceipt").mockImplementation(args => {
      const result = create(args);
      if (result.kind !== "failed") receipts.push(result.context);
      return result;
    }));
    for (const line of readFileSync(path, "utf8").split("\n")) {
      const command = parseCommand(line);
      if (!command) throw new Error("Invalid native socket command");
      expect(await handleSocketCommand(command)).toMatchObject({ outcome: "accept" });
    }
    expect(started).toEqual(["Alpha", "Bravo", "Charlie"]);
    expect(counts.at(-1)).toBe(0);
    expect(cleared).not.toHaveBeenCalled();
    expect(receipts).toHaveLength(3);
    expect(receipts.map(receipt => readFileSync(join(receipt.path, "input.txt"), "utf8"))).toEqual(["Alpha", "Bravo", "Charlie"]);
    for (const receipt of receipts) {
      expect(JSON.parse(readFileSync(join(receipt.path, "metadata.json"), "utf8"))).toMatchObject({ status: "received" });
    }
  }
});

const identities = z.array(z.object({ name: z.string(), input: z.string(), identity: z.string() }))
  .parse(JSON.parse(readFileSync(new URL("../../formal/speech-queue/selection-identity.json", import.meta.url), "utf8")));
for (const row of identities) test(`shared selection identity: ${row.name}`, () => {
  expect(selectionIdentity(row.input)).toBe(row.identity);
});

test("canonical equivalents deduplicate through daemon admission", async () => {
  spies.push(spyOn(input, "getRecordingState").mockReturnValue("idle"),
    spyOn(input, "getEffectiveRecordingState").mockReturnValue("idle"),
    spyOn(tts, "prepareSelectionReadStart").mockImplementation(() => new Promise(() => {})),
    spyOn(tts, "speakText").mockImplementation(() => ({ id: "read", generation: 1, done: Promise.resolve(),
      playerExited: Promise.resolve(), started: Promise.resolve({}), completion: Promise.resolve({}) })));
  await handleSocketCommand({ cmd: "speak_text", id: "owner", text: "Alpha", source: "selection", queue: true });
  await handleSocketCommand({ cmd: "speak_text", id: "composed", text: "café", source: "selection", queue: true });
  expect(await handleSocketCommand({ cmd: "speak_text", id: "decomposed", text: "cafe\u0301", source: "selection", queue: true }))
    .toMatchObject({ outcome: "noop", reason: "Already queued" });
});

test("marker-only Markdown cannot enqueue empty speech or clear a valid following read", async () => {
  const started: string[] = [];
  spies.push(spyOn(input, "getRecordingState").mockReturnValue("idle"),
    spyOn(input, "getEffectiveRecordingState").mockReturnValue("idle"),
    spyOn(tts, "prepareSelectionReadStart").mockImplementation(() => new Promise(() => {})),
    spyOn(tts, "speakText").mockImplementation(text => {
      started.push(text);
      if (!text.trim()) throw new Error("empty speech");
      return { id: text, generation: 1, done: Promise.resolve(), playerExited: Promise.resolve(),
        started: Promise.resolve({}), completion: Promise.resolve({}) };
    }));
  const cleared = spyOn(archive, "cancelQueuedSpeech"); spies.push(cleared);
  const press = (id: string, text: string) => handleSocketCommand({ cmd: "speak_text", id, text,
    source: "selection", format: "markdown", queue: true });
  await press("owner", "Alpha");
  for (const { id, text } of [{ id: "marker", text: "- " }, { id: "checkbox", text: "* [ ] " }]) {
    expect(await press(id, text)).toMatchObject({ outcome: "reject" });
  }
  await press("valid", "Charlie");
  await handleSocketCommand({ cmd: "read_next", request_id: "owner" });
  expect(started).toEqual(["Alpha", "Charlie"]);
  expect(cleared).not.toHaveBeenCalled();
});

test("a parked same-text read starts fresh while paused queued duplicates still hint", async () => {
  let paused = false;
  const started: string[] = [];
  spies.push(spyOn(input, "getRecordingState").mockReturnValue("idle"),
    spyOn(input, "getEffectiveRecordingState").mockReturnValue("idle"),
    spyOn(tts, "isPlaybackPaused").mockImplementation(() => paused),
    spyOn(tts, "prepareSelectionReadStart").mockImplementation(() => new Promise(() => {})),
    spyOn(tts, "speakText").mockImplementation(text => {
      started.push(text);
      return { id: text, generation: 1, done: Promise.resolve(), playerExited: Promise.resolve(),
        started: Promise.resolve({}), completion: Promise.resolve({}) };
    }));
  await handleSocketCommand({ cmd: "speak_text", id: "parked", text: "Alpha", source: "selection" });
  await handleSocketCommand({ cmd: "speak_text", id: "queued", text: "Bravo", source: "selection", queue: true });
  paused = true;
  expect(await handleSocketCommand({ cmd: "speak_text", id: "duplicate", text: "Bravo", source: "selection", queue: true }))
    .toMatchObject({ outcome: "noop", reason: "Already queued" });
  expect(await handleSocketCommand({ cmd: "speak_text", id: "fresh", text: "Alpha", source: "selection" }))
    .toMatchObject({ outcome: "accept" });
  expect(started).toEqual(["Alpha", "Alpha"]);
});

const modelPath = process.env.VOICELAYER_ADMISSION_CASES;
const rows = modelPath ? z.array(z.object({ playing: z.number().int(), pending: z.array(z.number().int()), suspended: z.boolean(),
    selected: z.number().int(), event: z.enum(["selection", "stop", "f5"]), decision: z.string(), preempted: z.boolean(),
    afterPlaying: z.number().int(), afterPending: z.array(z.number().int()) })).parse(JSON.parse(readFileSync(modelPath, "utf8"))) : [];
let replayed = 0;
const batchSize = 25;
for (let offset = 0; offset < rows.length; offset += batchSize) {
  test(`TLC admission decisions and post-states conform to daemon handlers: rows ${offset}-${Math.min(offset + batchSize, rows.length) - 1}`, async () => {
    let depth = 0, count = 0;
    const started: string[] = [];
    spies.push(spyOn(input, "getRecordingState").mockReturnValue("idle"),
      spyOn(input, "getEffectiveRecordingState").mockReturnValue("idle"),
      spyOn(tts, "getPlaybackQueueDepth").mockImplementation(() => depth),
      spyOn(tts, "stopPlayback").mockImplementation(() => { depth = 0; return true; }),
      spyOn(tts, "awaitCurrentPlayback").mockResolvedValue(undefined),
      spyOn(tts, "prepareSelectionReadStart").mockImplementation(() => new Promise(() => {})),
      spyOn(tts, "speakText").mockImplementation((_text, _profile, identity) => {
        const id = identity?.request_id ?? "";
        started.push(id); depth = 1;
        return { id, generation: 1, done: Promise.resolve(), playerExited: Promise.resolve(),
          started: Promise.resolve({}), completion: Promise.resolve({}) };
      }), spyOn(client, "broadcast").mockImplementation(event => { if (event.type === "read_queue") count = event.count; }));
    const cleared = spyOn(archive, "cancelQueuedSpeech"); spies.push(cleared);
    for (const [batchIndex, row] of rows.slice(offset, offset + batchSize).entries()) {
      const index = offset + batchIndex;
      resetSelectionReadQueueForTests(); depth = 0; count = 0;
      const press = (n: number, marker = "") => handleSocketCommand({ cmd: "speak_text", id: `model-${index}-${n}`,
        text: `${marker}Item ${n}`, source: "selection", format: "markdown", queue: true });
      if (row.playing) await press(row.playing);
      for (const n of row.pending) await press(n);
      if (row.suspended) { await handleSocketCommand({ cmd: "stop", retain_read_queue: true }); depth = 0; }
      if (row.preempted) { tts.preemptLongRead("external"); depth = 0; }
      cleared.mockClear(); started.length = 0;
      const response = await (row.event === "selection" ? press(row.selected, "- [x] ")
        : handleSocketCommand({ cmd: "stop", ...(row.event === "f5" ? { retain_read_queue: true } : {}) }));
      expect(response, `row ${index}`).toMatchObject(row.decision === "hint"
        ? { outcome: "noop", reason: "Already queued" } : { outcome: row.event === "stop" && (!row.playing || row.suspended) ? "noop" : "accept" });
      expect(count, `row ${index}`).toBe(row.afterPending.length);
      const launch = row.decision === "read_next" ? row.afterPlaying
        : row.decision === "speak_text" && (row.preempted || row.suspended || !row.playing) ? row.selected : 0;
      expect(started, `row ${index}`).toEqual(launch ? [`model-${index}-${launch}`] : []);
      if (row.event !== "stop") expect(cleared, `row ${index}`).not.toHaveBeenCalled();
      replayed++;
    }
  });
}
test.skipIf(!modelPath)("all TLC admission cases were replayed", () => {
  expect(replayed).toBe(rows.length);
  console.log(`Replayed ${replayed} TLC admission cases through daemon handlers`);
});
