import { afterEach, expect, spyOn, test } from "bun:test";
import { readFileSync } from "node:fs";
import { parseCommand } from "../socket-protocol";
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
  expect(await handleSocketCommand({ cmd: "speak_text", text: "unscoped", source: "selection" })).toMatchObject({ outcome: "reject" });
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
    for (const line of readFileSync(path, "utf8").split("\n")) {
      const command = parseCommand(line);
      if (!command) throw new Error("Invalid native socket command");
      expect(await handleSocketCommand(command)).toMatchObject({ outcome: "accept" });
    }
    expect(started).toEqual(["Alpha", "Bravo"]);
    expect(counts.at(-1)).toBe(1);
    expect(cleared).not.toHaveBeenCalled();
  }
});
