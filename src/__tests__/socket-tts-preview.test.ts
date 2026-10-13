import { afterEach, expect, spyOn, test } from "bun:test";
import * as tts from "../tts";
import * as input from "../input";
import * as booking from "../session-booking";
import { parseCommand } from "../socket-protocol";
import { handleSocketCommand } from "../socket-handlers";
import { hasActiveVoiceOperation } from "../voice-operation-reservation";
let mocks: Array<{mockRestore(): void}> = [];
afterEach(() => { for (const mock of mocks) mock.mockRestore(); mocks = []; });
test("preview accepts only known profiles and retains correlation id", () => {
  expect(parseCommand('{"cmd":"preview_tts_profile","profile":"long","id":"p"}'))
    .toEqual({cmd: "preview_tts_profile", profile: "long", id: "p"});
  expect(parseCommand('{"cmd":"preview_tts_profile","profile":"auto"}')).toBeNull();
});
test("preview uses existing speak with the selected profile, then releases reservation", async () => {
  mocks.push(spyOn(input, "getRecordingState").mockReturnValue("idle"));
  mocks.push(spyOn(tts, "getPlaybackQueueDepth").mockReturnValue(0));
  mocks.push(spyOn(booking, "isVoiceBooked").mockReturnValue({booked: false} as never));
  const speak = spyOn(tts, "speak").mockImplementation(async (_text, options) => {
    expect(hasActiveVoiceOperation()).toBe(true);
    expect(options).toMatchObject({profile: "long", waitForPlayback: true});
    return {playbackId: "sample"};
  }); mocks.push(speak);
  const ack = await handleSocketCommand({cmd: "preview_tts_profile", profile: "long", id: "p"} as never);
  expect(ack).toMatchObject({command: "preview_tts_profile", outcome: "accept", id: "p"});
  expect(speak).toHaveBeenCalledTimes(1);
  expect(hasActiveVoiceOperation()).toBe(false);
});
test("preview refuses recording without speaking", async () => {
  mocks.push(spyOn(input, "getRecordingState").mockReturnValue("recording"));
  const speak = spyOn(tts, "speak").mockResolvedValue({}); mocks.push(speak);
  expect(await handleSocketCommand({cmd: "preview_tts_profile", profile: "short"} as never))
    .toMatchObject({outcome: "reject", reason: "Recording in progress"});
  expect(speak).not.toHaveBeenCalled();
});
test("failed synthesis releases reservation and rejects with a reason", async () => {
  mocks.push(spyOn(input, "getRecordingState").mockReturnValue("idle"));
  mocks.push(spyOn(tts, "getPlaybackQueueDepth").mockReturnValue(0));
  mocks.push(spyOn(booking, "isVoiceBooked").mockReturnValue({booked: false} as never));
  mocks.push(spyOn(tts, "speak").mockRejectedValue(new Error("synthesis unavailable")));
  expect(await handleSocketCommand({cmd: "preview_tts_profile", profile: "short"} as never))
    .toMatchObject({outcome: "reject", reason: "synthesis unavailable"});
  expect(hasActiveVoiceOperation()).toBe(false);
});
