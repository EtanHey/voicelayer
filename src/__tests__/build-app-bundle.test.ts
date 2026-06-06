import { describe, expect, test } from "bun:test";
import { readFileSync } from "fs";
import { join } from "path";

// Static contract tests for flow-bar/build-app.sh: every runtime asset that
// src/ resolves relative to itself MUST be bundled into Resources/, or the
// installed app silently loses a capability on the next rebuild.
//
// AIDEV-NOTE: bug class with two real hits — #241 (models/silero_vad.onnx
// missing → recording broke) and 2026-06-05 (scripts/edge-tts-words.py
// missing → all daemon TTS broke with edge-tts exit code 2).

const buildScript = readFileSync(
  join(import.meta.dir, "..", "..", "flow-bar", "build-app.sh"),
  "utf-8",
);

describe("build-app.sh bundles runtime assets", () => {
  test("bundles the Silero VAD model (regression: #241)", () => {
    expect(buildScript).toContain("models/silero_vad.onnx");
    expect(buildScript).toMatch(/cp -R "\$REPO_ROOT\/models"/);
  });

  test("bundles scripts/edge-tts-words.py (TTS word-boundary synth)", () => {
    // tts.ts resolves ../scripts/edge-tts-words.py relative to bundled src/
    expect(buildScript).toContain("scripts/edge-tts-words.py");
    expect(buildScript).toMatch(
      /cp .*edge-tts-words\.py.*Resources\/scripts|cp .*"\$APP_DIR\/Contents\/Resources\/scripts"/,
    );
  });
});
