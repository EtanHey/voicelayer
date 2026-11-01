import { test, expect } from "bun:test";
import { join } from "path";

// Owner shutdown is permanent. Each control imports the actual production graph
// in a fresh preloaded process; providers/processes below it are explicit fakes.
for (const scenario of ["capture-maintenance", "capture-cancel", "capture-cleanup", "picker-refusal", "shutdown-picker-p", "shutdown-picker-w", "shutdown-picker-p-unknown", "shutdown-direct-w", "shutdown-adopted", "shutdown-legacy-w", "unexpected-exit", "intentional-exit", "late-old-exit"]) {
  test(`recognizer lifecycle: ${scenario}`, async () => {
    const child = Bun.spawn([process.execPath, "--preload", join(import.meta.dir, "setup/preload.ts"), join(import.meta.dir, "fixtures/recognizer-lifecycle-control.ts"), scenario], {
      cwd: join(import.meta.dir, "../.."), env: process.env, stdout: "pipe", stderr: "pipe",
    });
    const [stdout, stderr, code] = await Promise.all([new Response(child.stdout).text(), new Response(child.stderr).text(), child.exited]);
    const lines = stdout.trim().split("\n");
    expect({ code, terminal: lines.at(-1), stderr: code ? stderr : "" }).toEqual({ code: 0, terminal: `PASS ${scenario}`, stderr: "" });
    if (scenario.startsWith("shutdown-picker")) {
      const expectedTarget = scenario === "shutdown-picker-w" ? "whisper" : "parakeet";
      const receipt = JSON.parse(lines[0]!);
      expect(receipt).toEqual({ scenario, target: expectedTarget, startP: expectedTarget === "parakeet" ? 1 : 0,
        startW: expectedTarget === "whisper" ? 1 : 0, shutdownPendingBeforeCleanup: true });
      console.log(JSON.stringify(receipt));
    }
  });
}
