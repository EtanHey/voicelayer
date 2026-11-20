/**
 * A multi-utterance voice_ask is joined by assembleNarration. The one-piece path keeps the engine's
 * own MP3 untouched, so the joined file must carry the same bitrate the engine writes: 128 kbps for the
 * Qwen3 clone path (mlx-audio writes MP3 with ffmpeg's default -b:a 128k), 48 kbps for edge-tts.
 * Real ffmpeg and ffprobe on short synthetic inputs; no audio is played.
 */
import { describe, expect, it } from "bun:test";
import { existsSync, mkdirSync } from "fs";
import { join } from "path";
import { assembleNarration } from "../tts";
import { resolveBinary } from "../resolve-binary";
import { TEST_TMP } from "./setup/test-tmp";

const dir = join(TEST_TMP, "narration-assembly-bitrate");

function encodeSine(name: string, bitrate: string, hz: number): string {
  const ffmpeg = resolveBinary("ffmpeg");
  if (!ffmpeg) throw new Error("ffmpeg is required for this test");
  const out = join(dir, name);
  const result = Bun.spawnSync([ffmpeg, "-nostdin", "-y", "-f", "lavfi", "-t", "1.5", "-i",
    `sine=frequency=${hz}:sample_rate=24000`, "-ac", "1", "-b:a", bitrate, out], { env: process.env });
  if (result.exitCode !== 0) throw new Error(`ffmpeg could not encode ${name}`);
  return out;
}

/** The container's bit_rate in bits per second, as ffprobe reports it. */
function probeBitrate(file: string): number {
  const ffprobe = resolveBinary("ffprobe");
  if (!ffprobe) throw new Error("ffprobe is required for this test");
  const result = Bun.spawnSync([ffprobe, "-v", "error", "-show_entries", "format=bit_rate",
    "-of", "default=nw=1:nk=1", file], { env: process.env });
  return Number(new TextDecoder().decode(result.stdout).trim());
}

describe("assembled narration keeps the engine's MP3 bitrate", () => {
  it("joins 128 kbps clone utterances at 128 kbps, not 48 kbps", async () => {
    mkdirSync(dir, { recursive: true });
    const first = encodeSine("u0.mp3", "128k", 220);
    const second = encodeSine("u1.mp3", "128k", 330);
    const out = join(dir, "assembled-clone.mp3");

    await assembleNarration([{ file: first }, { silenceMs: 250 }, { file: second }], out, undefined, "128k");

    expect(existsSync(out)).toBe(true);
    const bitrate = probeBitrate(out);
    expect(bitrate).toBeGreaterThan(115_000);
    expect(bitrate).toBeLessThan(140_000);
  });

  it("keeps 48 kbps edge utterances at 48 kbps", async () => {
    mkdirSync(dir, { recursive: true });
    const first = encodeSine("e0.mp3", "48k", 220);
    const second = encodeSine("e1.mp3", "48k", 330);
    const out = join(dir, "assembled-edge.mp3");

    await assembleNarration([{ file: first }, { file: second }], out, undefined, "48k");

    const bitrate = probeBitrate(out);
    expect(bitrate).toBeGreaterThan(40_000);
    expect(bitrate).toBeLessThan(56_000);
  });
});
