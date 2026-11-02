/** Lane I's only fixture seam: seed owned take IDs here when its controller lands.
 * Decision code is always the production handleSocketCommand. Mic/playback edges remain silent.
 */
import { spyOn } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, existsSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { z } from "zod";
import * as input from "../../src/input";
import * as booking from "../../src/session-booking";
import * as socket from "../../src/socket-client";
import * as tts from "../../src/tts";
import { STOP_FILE } from "../../src/paths";
import { setRecordingState } from "../../src/recording-state";
import { handleSocketCommand } from "../../src/socket-handlers";
import type { SocketCommand } from "../../src/socket-protocol";

export const wireCase = z.object({ policy: z.enum(["Current", "Fixed"]), command: z.enum(["record", "cancel"]),
  origin: z.string(), phase: z.enum(["idle", "recording", "transcribing"]), before: z.record(z.string(), z.string()),
  target: z.enum(["A", "B"]), requestId: z.enum(["none", "A", "B", "stale"]), outcome: z.enum(["accept", "reject", "noop"]),
  token: z.enum(["none", "global", "A", "B"]) });
export const contractSchema = z.object({ pipelinePolicy: z.enum(["current", "fixed"]), cancelIdField: z.string(), captureIds: z.record(z.string(), z.number()) });
export type WireCase = z.infer<typeof wireCase>;
export function fixture() {
  if (process.env.VOICELAYER_TEST_ISOLATED !== "1") throw new Error("Run with bunfig.toml's normal isolation preload");
  const isolatedRoot = z.string().min(1).parse(process.env.VOICELAYER_TEST_RUN_ROOT);
  const oldGate = process.env.VOICELAYER_UPDATE_GATE_PATH;
  const gate = join(mkdtempSync(join(isolatedRoot, "formal-")), "gate.json");
  process.env.VOICELAYER_UPDATE_GATE_PATH = gate;
  writeFileSync(gate, JSON.stringify({ version: 1, kind: "OPEN", generation: 0, released: null }));
  mkdirSync(gate + ".admissions");
  const signal = spyOn(booking, "setCancelSignal").mockImplementation(() => {});
  const mocks = [signal, spyOn(input, "waitForInput").mockResolvedValue(null),
    spyOn(booking, "isVoiceBooked").mockReturnValue({ booked: true, ownedByUs: true }),
    spyOn(socket, "broadcast").mockImplementation(() => {}), spyOn(tts, "getPlaybackQueueDepth").mockReturnValue(0),
    spyOn(tts, "stopPlayback").mockImplementation(() => {}), spyOn(tts, "awaitCurrentPlayback").mockResolvedValue(undefined),
    spyOn(tts, "isPlaybackPaused").mockReturnValue(false)];
  return {
    async dispatch(row: WireCase, contract: z.infer<typeof contractSchema>) {
      booking.clearStopSignal(); booking.clearCancelSignal(); signal.mockClear();
      // Replace this seeding operation with Lane I's real owned-take fixture, using row.before and captureIds.
      setRecordingState(row.phase);
      const command: SocketCommand = row.command === "record" ? { cmd: "record", press_to_talk: true, timeout_seconds: 3600 } :
        { cmd: "cancel", [contract.cancelIdField]: contract.captureIds[row.requestId] ?? 999 };
      const reply = await handleSocketCommand(command);
      return { reply, signals: JSON.parse(JSON.stringify(signal.mock.calls)), stop: existsSync(STOP_FILE) ? readFileSync(STOP_FILE, "utf8") : "" };
    },
    close() {
      setRecordingState("idle"); booking.clearStopSignal(); booking.clearCancelSignal();
      mocks.reverse().forEach(mock => mock.mockRestore());
      if (oldGate === undefined) delete process.env.VOICELAYER_UPDATE_GATE_PATH;
      else process.env.VOICELAYER_UPDATE_GATE_PATH = oldGate;
    },
  };
}
