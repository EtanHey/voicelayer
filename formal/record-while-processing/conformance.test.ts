import { afterEach, expect, spyOn, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { z } from "zod";
import * as input from "../../src/input";
import * as booking from "../../src/session-booking";
import * as socket from "../../src/socket-client";
import * as tts from "../../src/tts";
import { setRecordingState } from "../../src/recording-state";
import { handleSocketCommand } from "../../src/socket-handlers";

const path = process.env.VOICELAYER_RECORD_TLC_CASES;
const isolated = process.env.VOICELAYER_TEST_ISOLATED === "1";
const originalGate = process.env.VOICELAYER_UPDATE_GATE_PATH;
afterEach(() => {
  if (!isolated) return;
  setRecordingState("idle");
  booking.clearCancelSignal();
  if (originalGate === undefined) delete process.env.VOICELAYER_UPDATE_GATE_PATH;
  else process.env.VOICELAYER_UPDATE_GATE_PATH = originalGate;
});
test.skipIf(!path || !isolated)("TLC current socket admission agrees with the real handler", async () => {
  expect(process.env.VOICELAYER_TEST_ISOLATED).toBe("1");
  const isolatedRoot = z.string().min(1).parse(process.env.VOICELAYER_TEST_RUN_ROOT);
  const gatePath = join(mkdtempSync(join(isolatedRoot, "lane-g-")), "gate.json");
  process.env.VOICELAYER_UPDATE_GATE_PATH = gatePath;
  writeFileSync(gatePath, JSON.stringify({ version: 1, kind: "OPEN", generation: 0, released: null }));
  mkdirSync(gatePath + ".admissions");
  const cases = z.array(z.object({ state: z.enum(["idle", "transcribing"]),
    outcome: z.enum(["accept", "reject"]) })).min(2).parse(JSON.parse(readFileSync(z.string().parse(path), "utf8")));
  const wait = spyOn(input, "waitForInput").mockResolvedValue(null);
  const owned = spyOn(booking, "isVoiceBooked").mockReturnValue({ booked: true, ownedByUs: true });
  const broadcast = spyOn(socket, "broadcast").mockImplementation(() => {});
  const depth = spyOn(tts, "getPlaybackQueueDepth").mockReturnValue(0);
  try {
    for (const row of cases) {
      setRecordingState(row.state);
      wait.mockClear();
      const reply = await handleSocketCommand({ cmd: "record", press_to_talk: true, timeout_seconds: 3600 });
      expect(reply).toMatchObject({ outcome: row.outcome });
      if (row.outcome === "reject") expect(reply).toMatchObject({ reason: "busy" });
      expect(wait).toHaveBeenCalledTimes(row.outcome === "accept" ? 1 : 0);
    }
    console.info(`Replayed ${cases.length} TLC admission equivalence classes through real handleSocketCommand`);
    booking.setCancelSignal();
    expect(input.consumeCancelSignalForRecording()).toBe(true);
    expect(input.consumeCancelSignalForRecording()).toBe(false);
  } finally {
    [wait, owned, broadcast, depth].forEach(mock => mock.mockRestore());
  }
});
