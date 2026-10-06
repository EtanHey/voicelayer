import { describe, expect, test } from "bun:test";
import { join } from "path";

const repoRoot = join(import.meta.dir, "..", "..");

for (const script of ["benchmark-stt-decode.ts", "stt-long-dictation-ab.ts"]) {
  describe(script, () => {
    function run(args: string[]) {
      const result = Bun.spawnSync(
        [process.execPath, join(repoRoot, "scripts", script), ...args],
        { cwd: repoRoot, stdout: "pipe", stderr: "pipe" },
      );
      return {
        exitCode: result.exitCode,
        output: result.stdout.toString() + result.stderr.toString(),
      };
    }

    test("requires explicit audio before resolving models or starting a server", () => {
      const result = run([]);
      expect(result.exitCode).toBe(1);
      expect(result.output).toContain("Usage:");
      expect(result.output).toContain("--audio PATH is required");
      expect(result.output).not.toContain("No whisper model found");
      expect(result.output).not.toContain("not found");
    });

    test("help succeeds without selecting recordings", () => {
      const result = run(["--help"]);
      expect(result.exitCode).toBe(0);
      expect(result.output).toContain("--audio PATH");
      expect(result.output).toContain("Required");
    });

    test("reports a missing explicitly supplied file", () => {
      const audio = join(repoRoot, ".test-tmp", "absent-benchmark-fixture.wav");
      const result = run(["--audio", audio]);
      expect(result.exitCode).toBe(1);
      expect(result.output).toContain(`Audio not found: ${audio}`);
    });
  });
}
