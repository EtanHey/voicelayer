import { readFileSync, rmSync } from "node:fs";
import { parseWavAudioInfo } from "../../stt-pause-map";

/** A successful `say` can leave a 4096-byte AIFF header with no sound frames. */
export function hasAiffAudio(path: string): boolean {
  try {
    const data = readFileSync(path);
    if (data.length <= 4096 || data.toString("ascii", 0, 4) !== "FORM" ||
        !["AIFF", "AIFC"].includes(data.toString("ascii", 8, 12))) return false;
    let frames = false;
    let sound = false;
    for (let offset = 12; offset + 8 <= data.length;) {
      const kind = data.toString("ascii", offset, offset + 4);
      const size = data.readUInt32BE(offset + 4);
      const start = offset + 8;
      if (start + size > data.length) return false;
      if (kind === "COMM" && size >= 18) frames = data.readUInt32BE(start + 2) > 0;
      if (kind === "SSND" && size >= 8) {
        const padding = data.readUInt32BE(start);
        sound = size - 8 - padding >= 1024 &&
          data.subarray(start + 8 + padding, start + size).some(byte => byte !== 0);
      }
      offset = start + size + (size % 2);
    }
    return frames && sound;
  } catch { return false; }
}

/** Reject stale header-only and silence-only converted fixtures too. */
export function hasWavAudio(path: string): boolean {
  try {
    const data = readFileSync(path);
    const info = parseWavAudioInfo(data);
    if (info === null || info.audioFormat !== 1 || info.sampleRate !== 16000 ||
        info.channels !== 1 || info.bitsPerSample !== 16 || info.dataSize < 1024 ||
        info.dataOffset + info.dataSize > data.length) return false;
    for (let offset = info.dataOffset; offset + 2 <= info.dataOffset + info.dataSize; offset += 2) {
      if (Math.abs(data.readInt16LE(offset)) > 2) return true;
    }
    return false;
  } catch { return false; }
}

function runSay(path: string, text: string): string | null {
  try {
    const result = Bun.spawnSync(["say", "-o", path, text], {
      env: process.env, timeout: 10_000,
    });
    return result.exitCode === 0 ? null : `say exited ${result.exitCode}: ${result.stderr.toString().trim()}`;
  } catch (error) { return String(error); }
}

/** Null means validated audio. A reason means the caller must register a skip. */
export function prepareSpeechAiff(
  path: string,
  text: string,
  synthesize: (path: string, text: string) => string | null = runSay,
): string | null {
  if (hasAiffAudio(path)) return null;
  const failures: string[] = [];
  for (let attempt = 1; attempt <= 2; attempt++) {
    rmSync(path, { force: true });
    const error = synthesize(path, text);
    if (error === null && hasAiffAudio(path)) return null;
    failures.push(`attempt ${attempt}: ${error ?? "say exited 0 but AIFF has no usable COMM/SSND audio payload"}`);
  }
  rmSync(path, { force: true });
  return `speech synthesis unavailable in this process/session after one retry (${failures.join("; ")}). ` +
    "The macOS test sandbox in a non-GUI/ssh session can produce header-only output; run from the GUI session. No speech assertions ran.";
}
