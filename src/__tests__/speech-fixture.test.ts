import { describe, expect, test } from "bun:test";
import { existsSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { hasAiffAudio, hasWavAudio, prepareSpeechAiff } from "./setup/speech-fixture";

function aiff(frames: number): Buffer {
  const data = Buffer.alloc(54 + frames * 2);
  data.write("FORM"); data.writeUInt32BE(data.length - 8, 4); data.write("AIFF", 8);
  data.write("COMM", 12); data.writeUInt32BE(18, 16);
  data.writeUInt16BE(1, 20); data.writeUInt32BE(frames, 22); data.writeUInt16BE(16, 26);
  data.write("SSND", 38); data.writeUInt32BE(8 + frames * 2, 42);
  data.fill(1, 54);
  return data;
}

function fixture(body: (path: string) => void): void {
  const root = mkdtempSync(join(process.env.VOICELAYER_TEST_RUN_ROOT!, "speech-"));
  try { body(join(root, "speech.aiff")); }
  finally { rmSync(root, { recursive: true, force: true }); }
}

describe("speech fixture audio validation", () => {
  for (const [label, empty] of [
    ["empty file", Buffer.alloc(0)],
    ["header without SSND", Buffer.alloc(4096)],
    ["SSND with no sound frames", aiff(0)],
  ] satisfies [string, Buffer][]) {
    test(`rejects ${label} after exit 0, retries once, and reports unavailable`, () => fixture(path => {
      let attempts = 0;
      const failure = prepareSpeechAiff(path, "probe", output => {
        attempts++;
        writeFileSync(output, empty);
        return null;
      });
      expect(attempts).toBe(2);
      expect(failure).toContain("speech synthesis unavailable in this process/session");
      expect(failure).toContain("no usable COMM/SSND audio payload");
      expect(existsSync(path)).toBe(false);
    }));
  }

  test("replaces a stale empty cache and accepts real audio on the one retry", () => fixture(path => {
    writeFileSync(path, Buffer.alloc(4096));
    let attempts = 0;
    const failure = prepareSpeechAiff(path, "probe", output => {
      attempts++;
      expect(existsSync(output)).toBe(false);
      writeFileSync(output, attempts === 1 ? aiff(0) : aiff(4096));
      return null;
    });
    expect(failure).toBeNull();
    expect(attempts).toBe(2);
    expect(hasAiffAudio(path)).toBe(true);
    expect(prepareSpeechAiff(path, "probe", () => { throw new Error("valid cache must be reused"); })).toBeNull();
  }));

  test("rejects truncated SSND even if the header claims sound frames", () => fixture(path => {
    writeFileSync(path, aiff(4096).subarray(0, 4200));
    expect(hasAiffAudio(path)).toBe(false);
  }));

  test("does not accept a stale WAV containing only silent padding", () => fixture(path => {
    const data = Buffer.alloc(44 + 32000);
    data.write("RIFF"); data.writeUInt32LE(data.length - 8, 4); data.write("WAVE", 8);
    data.write("fmt ", 12); data.writeUInt32LE(16, 16); data.writeUInt16LE(1, 20);
    data.writeUInt16LE(1, 22); data.writeUInt32LE(16000, 24);
    data.writeUInt32LE(32000, 28); data.writeUInt16LE(2, 32); data.writeUInt16LE(16, 34);
    data.write("data", 36); data.writeUInt32LE(32000, 40);
    writeFileSync(path, data);
    expect(hasWavAudio(path)).toBe(false);
    data.writeInt16LE(-1, 100);
    data.writeInt16LE(1, 102);
    writeFileSync(path, data);
    expect(hasWavAudio(path)).toBe(false);
    data.writeInt16LE(8192, 100);
    writeFileSync(path, data);
    expect(hasWavAudio(path)).toBe(true);
  }));
});

describe("required speech coverage in a real test process", () => {
  for (const control of [
    { name: "required empty fixture fails", required: "1", frames: 0, outcome: "failure" },
    { name: "optional empty fixture skips loudly", required: undefined, frames: 0, outcome: "skip" },
    { name: "required good fixture executes assertions", required: "1", frames: 4096, outcome: "pass" },
  ]) {
    test(control.name, () => fixture(path => {
      const testPath = `${path}.test.ts`;
      writeFileSync(testPath, `
        import { test, expect } from "bun:test";
        import { writeFileSync } from "node:fs";
        import { hasAiffAudio, prepareSpeechAiff, speechFixtureAvailable } from ${JSON.stringify(join(import.meta.dir, "setup/speech-fixture.ts"))};
        const path = ${JSON.stringify(path)};
        const failure = prepareSpeechAiff(path, "probe", output => {
          writeFileSync(output, Buffer.from(${JSON.stringify([...aiff(control.frames)])}));
          return null;
        });
        const ready = speechFixtureAvailable("speech policy control", failure);
        (ready ? test : test.skip)("speech assertions execute", () => {
          expect(hasAiffAudio(path)).toBe(true);
        });
      `);
      const child = Bun.spawnSync([process.execPath, "test", testPath], {
        env: { ...process.env, VOICELAYER_TEST_REQUIRE_SPEECH: control.required },
        timeout: 10_000,
      });
      const output = child.stdout.toString() + child.stderr.toString();
      expect(child.exitCode === 0).toBe(control.outcome !== "failure");
      if (control.outcome === "pass") {
        expect(output).toContain("1 pass");
        expect(output).not.toContain("SKIPPING");
      } else {
        expect(output).toContain("speech synthesis unavailable in this process/session after one retry");
        expect(output).toContain("no usable COMM/SSND audio payload");
        expect(output).toContain(control.outcome === "skip" ? "1 skip" : "1 fail");
        expect(output.includes("SKIPPING")).toBe(control.outcome === "skip");
      }
    }), 15_000);
  }
});
