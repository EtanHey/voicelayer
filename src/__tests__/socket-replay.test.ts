import { afterEach, beforeEach, describe, expect, it, spyOn } from "bun:test";
import { writeFileSync } from "fs";
import { TEST_TMP } from "./setup/test-tmp";
import * as tts from "../tts";
import * as input from "../input";
import * as recording from "../recording-state";
import { handleSocketCommand } from "../socket-handlers";

describe("socket Replay routing", () => {
  let spies: ReturnType<typeof spyOn>[];
  beforeEach(() => {
    spies = [spyOn(input, "getRecordingState").mockReturnValue("idle"),
      spyOn(recording, "getEffectiveRecordingState").mockReturnValue("idle"),
      spyOn(tts, "getPlaybackQueueDepth").mockReturnValue(1)];
  });
  afterEach(() => { for (const spy of spies) spy.mockRestore(); });

  it("acknowledges a restart on the existing owner without enqueueing history", () => {
    const restart = spyOn(tts, "restartPlayback").mockReturnValue(true);
    const enqueue = spyOn(tts, "playAudioNonBlocking"); spies.push(restart, enqueue);
    expect(handleSocketCommand({ cmd: "replay", id: "click" })).toMatchObject({ command: "replay", id: "click", outcome: "accept" });
    expect(restart).toHaveBeenCalledTimes(1); expect(enqueue).not.toHaveBeenCalled();
  });

  for (const state of ["recording", "transcribing"] as const) it(`refuses Replay during ${state}`, () => {
    spies[0].mockReturnValue(state);
    const restart = spyOn(tts, "restartPlayback"); spies.push(restart);
    expect(handleSocketCommand({ cmd: "replay" })).toMatchObject({ outcome: "reject", reason: "busy" });
    expect(restart).not.toHaveBeenCalled();
  });

  it("returns a rejection when the current owner cannot restart", () => {
    spies.push(spyOn(tts, "restartPlayback").mockReturnValue(false));
    expect(handleSocketCommand({ cmd: "replay" })).toMatchObject({ outcome: "reject" });
  });

  it("replays the most recent retained history entry when idle", () => {
    const file = `${TEST_TMP}/socket-replay.mp3`; writeFileSync(file, "fixture");
    spies[2].mockReturnValue(0);
    spies.push(spyOn(tts, "getHistoryEntry").mockReturnValue({ id: 0, text: "Retained speech.", voice: "fixture", file, timestamp: 0 }));
    const enqueue = spyOn(tts, "playAudioNonBlocking").mockImplementation(() => undefined as any); spies.push(enqueue);
    expect(handleSocketCommand({ cmd: "replay" })).toMatchObject({ outcome: "accept" });
    expect(enqueue).toHaveBeenCalledWith(file, { text: "Retained speech.", voice: "fixture" });
  });

  it("reports an empty idle history truthfully", () => {
    spies[2].mockReturnValue(0); spies.push(spyOn(tts, "getHistoryEntry").mockReturnValue(undefined));
    expect(handleSocketCommand({ cmd: "replay" })).toMatchObject({ outcome: "noop", reason: "nothing to replay" });
  });
});
