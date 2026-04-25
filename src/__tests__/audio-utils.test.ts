import { describe, expect, it } from "bun:test";
import {
  downmixPCM16ToMono,
  parseNativeInputFormat,
  resamplePCM16,
} from "../audio-utils";

describe("audio-utils", () => {
  it("parses native input sample rate and channel count from rec probe output", () => {
    const format = parseNativeInputFormat(`
Input File     : 'default' (coreaudio)
Channels       : 2
Sample Rate    : 48000
Precision      : 32-bit
Sample Encoding: 32-bit Signed Integer PCM
`);

    expect(format).toEqual({ sampleRate: 48000, channels: 2 });
  });

  it("falls back to mono 16kHz when rec probe output is incomplete", () => {
    const format = parseNativeInputFormat("garbage");
    expect(format).toEqual({ sampleRate: 16000, channels: 1 });
  });

  it("downmixes stereo PCM16 to mono by averaging channels", () => {
    const pcm = new Uint8Array(8);
    const view = new DataView(pcm.buffer);
    view.setInt16(0, 1000, true); // left sample 1
    view.setInt16(2, 3000, true); // right sample 1
    view.setInt16(4, -2000, true); // left sample 2
    view.setInt16(6, 2000, true); // right sample 2

    const mono = downmixPCM16ToMono(pcm, 2);
    const monoView = new DataView(mono.buffer);

    expect(mono.byteLength).toBe(4);
    expect(monoView.getInt16(0, true)).toBe(2000);
    expect(monoView.getInt16(2, true)).toBe(0);
  });

  it("resamples a mono PCM16 buffer without changing silence", () => {
    const silence = new Uint8Array(320);
    const resampled = resamplePCM16(silence, 48000, 16000);
    expect(resampled.every((b) => b === 0)).toBe(true);
  });
});
