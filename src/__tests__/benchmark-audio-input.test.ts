import { describe, expect, test } from "bun:test";
import { mkdtempSync, mkdirSync, rmSync, utimesSync, writeFileSync } from "fs";
import { join } from "path";
import { TEST_TMP } from "./setup/test-tmp";
import { findDefaultAudio } from "../../scripts/benchmark-stt-decode";

const repoRoot = join(import.meta.dir, "..", "..");

for (const script of ["benchmark-stt-decode.ts", "stt-long-dictation-ab.ts"]) {
  describe(script, () => {
    function run(args: string[]) {
      const fixtureHome = mkdtempSync(join(TEST_TMP, "benchmark-home-"));
      try {
        const result = Bun.spawnSync(
          [process.execPath, join(repoRoot, "scripts", script), ...args],
          {
            cwd: repoRoot, stdout: "pipe", stderr: "pipe",
            env: { ...process.env, HOME: fixtureHome },
          },
        );
        return {
          exitCode: result.exitCode,
          output: result.stdout.toString() + result.stderr.toString(),
        };
      } finally {
        rmSync(fixtureHome, { recursive: true, force: true });
      }
    }

    test("reports an empty isolated archive before model or server setup", () => {
      const result = run([]);
      expect(result.exitCode).toBe(1);
      expect(result.output).toContain("Usage:");
      expect(result.output).toContain("No audio recordings found. Pass --audio PATH.");
      expect(result.output).not.toContain("No whisper model found");
    });

    test("help documents optional archive discovery", () => {
      const result = run(["--help"]);
      expect(result.exitCode).toBe(0);
      expect(result.output).toContain("--audio PATH");
      expect(result.output).toContain("~/.local/share/voicelayer/recordings");
    });

    test("an explicit audio argument overrides empty archive discovery", () => {
      const audio = join(repoRoot, ".test-tmp", "absent-benchmark-fixture.wav");
      const result = run(["--audio", audio]);
      expect(result.exitCode).toBe(1);
      expect(result.output).toContain(`Audio not found: ${audio}`);
      expect(result.output).not.toContain("No audio recordings found");
    });
  });
}

test("default audio discovery selects the three newest WAVs from a synthetic archive", () => {
  const root = mkdtempSync(join(TEST_TMP, "benchmark-archive-"));
  try {
    const paths: string[] = [];
    for (let i = 0; i < 4; i++) {
      const dir = join(root, "fixture-date", `recording-${i}`);
      mkdirSync(dir, { recursive: true });
      const audio = join(dir, "audio.wav");
      writeFileSync(audio, "synthetic fixture");
      utimesSync(audio, i + 1, i + 1);
      paths.push(audio);
    }
    expect(findDefaultAudio(root)).toEqual([paths[3], paths[2], paths[1]]);
    expect(findDefaultAudio(join(root, "absent"))).toEqual([]);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
