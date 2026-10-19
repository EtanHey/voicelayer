import { describe, expect, it } from "bun:test";
import {
  isDeadDeviceChunk,
  isDeadDevicePcm,
  locateMicLoss,
  micDisconnectClock,
  micDisconnectNote,
} from "../mic-disconnect";
import { parseCommand } from "../socket-protocol";

const RATE = 16_000;

function chunkOf(samples: number[]): Uint8Array {
  const chunk = new Uint8Array(samples.length * 2);
  const view = new DataView(chunk.buffer);
  samples.forEach((sample, index) => view.setInt16(index * 2, sample, true));
  return chunk;
}

// 100 ms chunks keep the window arithmetic readable.
const repeat = (pattern: number[]) => chunkOf(Array.from({ length: 1600 }, (_, i) => pattern[i % pattern.length]!));
const speech = repeat([0, 900, -1200, 40]);
// His quietest live floor (06:33 take): ~-75 dBFS, range >= 36 LSB.
const quietButLive = repeat([0, 18, -3, -18, 7, 1]);
const zeros = repeat([0]);
const dc = repeat([-7]);
// Dead-device dither, HALLU1 06:33: every sample in {-1, 0, +1}.
const dither = repeat([0, 1, 0, -1]);
const times = (chunk: Uint8Array, n: number) => Array.from({ length: n }, () => chunk);

describe("mic disconnect (MICDROP2)", () => {
  it("calls only a chunk spanning <= 2 LSB dead: zeros, DC, +/-1 dither", () => {
    expect([zeros, dc, dither].map(isDeadDeviceChunk)).toEqual([true, true, true]);
    expect(isDeadDeviceChunk(speech)).toBe(false);
    expect(isDeadDeviceChunk(chunkOf([0, 1, -2, 0]))).toBe(false);
    expect(isDeadDeviceChunk(quietButLive)).toBe(false);
  });

  it("varying DC: each chunk is dead per chunk, the whole span is not dead to HALLU1's span rule", () => {
    const low = chunkOf([5, 5, 5, 5]);
    const high = chunkOf([40, 40, 40, 40]);
    expect(isDeadDeviceChunk(low) && isDeadDeviceChunk(high)).toBe(true);
    const span = new Uint8Array([...low, ...high]);
    expect(isDeadDevicePcm(new DataView(span.buffer), 0, 8)).toBe(false);
  });

  it("locates the boundary where the trailing dead run starts; interior gated gaps stay in", () => {
    const chunks = [...times(speech, 5), ...times(zeros, 3), ...times(speech, 7), ...times(dither, 5)];
    expect(locateMicLoss(chunks, "recorder-ended", RATE)).toEqual({
      reason: "recorder-ended", atMs: 1_500, decodeBytes: 15 * 3_200,
    });
    // Lost while live (the device just stopped delivering): the boundary is the end, nothing excluded.
    expect(locateMicLoss(times(speech, 3), "device-removed", RATE)).toEqual({
      reason: "device-removed", atMs: 300, decodeBytes: 3 * 3_200,
    });
  });

  it("never live: no loss point, decode input unchanged", () => {
    expect(locateMicLoss(times(dither, 10), "device-not-alive", RATE)).toEqual({
      reason: "device-not-alive", atMs: null, decodeBytes: 10 * 3_200,
    });
    expect(micDisconnectNote({ reason: "recorder-ended", atMs: null, decodeBytes: 0 })).toBe("Mic produced no signal");
  });

  it("formats the note with an m:ss clock", () => {
    expect(micDisconnectClock(0)).toBe("0:00");
    expect(micDisconnectClock(42_400)).toBe("0:42");
    expect(micDisconnectClock(61_600)).toBe("1:02");
    expect(micDisconnectNote({ reason: "device-removed", atMs: 125_000, decodeBytes: 1 })).toBe("Mic disconnected at 2:05");
  });

  it("parses VoiceBar's input_device_lost command, only with a known CoreAudio reason", () => {
    expect(parseCommand(JSON.stringify({ cmd: "input_device_lost", reason: "device-removed" })))
      .toEqual({ cmd: "input_device_lost", reason: "device-removed" });
    expect(parseCommand(JSON.stringify({ cmd: "input_device_lost", reason: "device-not-alive", id: "a" })))
      .toEqual({ cmd: "input_device_lost", reason: "device-not-alive", id: "a" });
    // Recorder EOF is the daemon's own evidence; VoiceBar cannot claim it, or anything else.
    for (const reason of ["recorder-ended", "dead-signal", undefined]) {
      expect(parseCommand(JSON.stringify({ cmd: "input_device_lost", reason }))).toBeNull();
    }
  });
});
