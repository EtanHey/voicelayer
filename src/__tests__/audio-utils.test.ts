import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import {
  __resetNativeInputFormatProbesForTests,
  __setNativeInputFormatProbesForTests,
  detectNativeInputFormat,
  detectNativeSampleRate,
  downmixPCM16ToMono,
  noteRecorderStderrForNativeInputFormat,
  parseNativeInputFormat,
  resamplePCM16,
  resetNativeInputFormatCache,
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

  it("downmixes stereo PCM16 to mono by preserving each frame's dominant channel", () => {
    const pcm = new Uint8Array(8);
    const view = new DataView(pcm.buffer);
    view.setInt16(0, 1000, true); // left sample 1
    view.setInt16(2, 3000, true); // right sample 1
    view.setInt16(4, -2000, true); // left sample 2
    view.setInt16(6, 2000, true); // right sample 2

    const mono = downmixPCM16ToMono(pcm, 2);
    const monoView = new DataView(mono.buffer);

    expect(mono.byteLength).toBe(4);
    expect(monoView.getInt16(0, true)).toBe(3000);
    expect(monoView.getInt16(2, true)).toBe(-2000);
  });

  it("does not phase-cancel anti-phase stereo into silence", () => {
    const pcm = new Uint8Array(4);
    const view = new DataView(pcm.buffer);
    view.setInt16(0, 12000, true);
    view.setInt16(2, -12000, true);

    const mono = downmixPCM16ToMono(pcm, 2);
    const monoView = new DataView(mono.buffer);

    expect(Math.abs(monoView.getInt16(0, true))).toBe(12000);
  });

  it("resamples a mono PCM16 buffer without changing silence", () => {
    const silence = new Uint8Array(320);
    const resampled = resamplePCM16(silence, 48000, 16000);
    expect(resampled.every((b) => b === 0)).toBe(true);
  });
});

describe("native input format cache", () => {
  // Module state: another suite in the same process may have measured the real
  // device already, so isolate on both sides.
  beforeEach(() => {
    resetNativeInputFormatCache();
  });

  afterEach(() => {
    __resetNativeInputFormatProbesForTests();
    resetNativeInputFormatCache();
  });

  const PROBE_OUTPUT = `
Input File     : 'default' (coreaudio)
Channels       : 2
Sample Rate    : 48000
`;

  it("probes the device once across two detectNativeInputFormat() calls", () => {
    let probes = 0;
    __setNativeInputFormatProbesForTests({
      sync: () => {
        probes++;
        return { stderr: PROBE_OUTPUT, stdout: "" };
      },
    });

    expect(detectNativeInputFormat()).toEqual({
      sampleRate: 48000,
      channels: 2,
    });
    expect(detectNativeInputFormat()).toEqual({
      sampleRate: 48000,
      channels: 2,
    });
    expect(probes).toBe(1);
  });

  it("shares the cache with detectNativeSampleRate()", () => {
    let probes = 0;
    __setNativeInputFormatProbesForTests({
      sync: () => {
        probes++;
        return { stderr: PROBE_OUTPUT, stdout: "" };
      },
    });

    expect(detectNativeInputFormat().sampleRate).toBe(48000);
    expect(detectNativeSampleRate()).toBe(48000);
    expect(probes).toBe(1);
  });

  it("probes again after resetNativeInputFormatCache()", () => {
    let probes = 0;
    __setNativeInputFormatProbesForTests({
      sync: () => {
        probes++;
        return { stderr: PROBE_OUTPUT, stdout: "" };
      },
    });

    detectNativeInputFormat();
    resetNativeInputFormatCache();
    detectNativeInputFormat();

    expect(probes).toBe(2);
  });

  // The latency claim of this PR: once warm, the capture path pays nothing for
  // the format. `waitForInput` itself cannot be run here (it needs sox, Silero
  // and a real mic — every other suite mocks it), so the assertion sits on the
  // one call it makes synchronously before spawning the recorder.
  it("keeps the warm lookup off the probe's critical path", () => {
    __setNativeInputFormatProbesForTests({
      sync: () => {
        Bun.sleepSync(200);
        return { stderr: PROBE_OUTPUT, stdout: "" };
      },
    });

    detectNativeInputFormat(); // cold: pays the probe

    const started = performance.now();
    detectNativeInputFormat();
    const warmMs = performance.now() - started;

    expect(warmMs).toBeLessThan(5);
  });

  it("falls back to the default format without caching a failed probe", () => {
    let probes = 0;
    __setNativeInputFormatProbesForTests({
      sync: () => {
        probes++;
        return null;
      },
    });

    expect(detectNativeInputFormat()).toEqual({
      sampleRate: 16000,
      channels: 1,
    });
    expect(detectNativeInputFormat()).toEqual({
      sampleRate: 16000,
      channels: 1,
    });
    expect(probes).toBe(2);
  });

  it("does not cache probe output that never reached the device", () => {
    let probes = 0;
    __setNativeInputFormatProbesForTests({
      sync: () => {
        probes++;
        return { stderr: "rec FAIL formats: can't open input device", stdout: "" };
      },
    });

    expect(detectNativeInputFormat()).toEqual({
      sampleRate: 16000,
      channels: 1,
    });
    detectNativeInputFormat();
    expect(probes).toBe(2);
  });

  it("drops the cache when rec reports a device failure", () => {
    let probes = 0;
    __setNativeInputFormatProbesForTests({
      sync: () => {
        probes++;
        return { stderr: PROBE_OUTPUT, stdout: "" };
      },
    });

    detectNativeInputFormat();
    expect(
      noteRecorderStderrForNativeInputFormat(
        "rec FAIL formats: can not open audio device",
      ),
    ).toBe("invalidated");
    detectNativeInputFormat();

    expect(probes).toBe(2);
  });

  it("keeps the cache for ordinary rec chatter", () => {
    let probes = 0;
    __setNativeInputFormatProbesForTests({
      sync: () => {
        probes++;
        return { stderr: PROBE_OUTPUT, stdout: "" };
      },
    });

    detectNativeInputFormat();
    expect(
      noteRecorderStderrForNativeInputFormat("rec WARN alsa: over-run"),
    ).toBeNull();
    detectNativeInputFormat();

    expect(probes).toBe(1);
  });

  // The exact strings sox 14.4.2 emits under `-V2 … -q -` when the requested
  // format is not the device's. Captured from `rec` on this machine.
  it("corrects the cache from sox's sample-rate mismatch warning", () => {
    let probes = 0;
    __setNativeInputFormatProbesForTests({
      sync: () => {
        probes++;
        return { stderr: PROBE_OUTPUT, stdout: "" };
      },
    });

    detectNativeInputFormat();
    expect(
      noteRecorderStderrForNativeInputFormat(
        "/opt/homebrew/bin/rec WARN formats: can't set sample rate 48000; using 16000",
      ),
    ).toEqual({ sampleRate: 16000, channels: 2 });

    // Corrected, not merely dropped — no re-probe.
    expect(detectNativeInputFormat()).toEqual({
      sampleRate: 16000,
      channels: 2,
    });
    expect(probes).toBe(1);
  });

  it("corrects the cache from sox's channel-count mismatch warning", () => {
    __setNativeInputFormatProbesForTests({
      sync: () => ({ stderr: PROBE_OUTPUT, stdout: "" }),
    });

    detectNativeInputFormat();
    noteRecorderStderrForNativeInputFormat(
      "/opt/homebrew/bin/rec WARN formats: can't set 2 channels; using 1",
    );

    expect(detectNativeInputFormat()).toEqual({
      sampleRate: 48000,
      channels: 1,
    });
  });

  it("corrects both halves when sox rejects rate and channels together", () => {
    __setNativeInputFormatProbesForTests({
      sync: () => ({ stderr: PROBE_OUTPUT, stdout: "" }),
    });

    detectNativeInputFormat();
    noteRecorderStderrForNativeInputFormat(
      "rec WARN formats: can't set sample rate 8000; using 44100\n" +
        "rec WARN formats: can't set 4 channels; using 1",
    );

    expect(detectNativeInputFormat()).toEqual({
      sampleRate: 44100,
      channels: 1,
    });
  });

  it("adopts a mismatch warning even with no cached format to correct", () => {
    __setNativeInputFormatProbesForTests({
      sync: () => ({ stderr: PROBE_OUTPUT, stdout: "" }),
    });

    expect(
      noteRecorderStderrForNativeInputFormat(
        "rec WARN formats: can't set sample rate 16000; using 44100",
      ),
    ).toEqual({ sampleRate: 44100, channels: 1 });
  });

  it("ignores empty rec stderr", () => {
    expect(noteRecorderStderrForNativeInputFormat("")).toBeNull();
  });
});
