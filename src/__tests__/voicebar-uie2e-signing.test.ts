import { bundleFixtureRoot } from "./setup/bundle-fixtures";
import { describe, expect, test } from "bun:test";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { join } from "node:path";

// Real subprocesses: standalone p95 <= 60 ms; 4x rounded up, with a 5 s scheduling floor.
const SUBPROCESS_TEST_TIMEOUT_MS = 5_000;

// Exercise the build script's actual policy without building/signing/launching anything.
describe("UI E2E ad-hoc signing boundary", () => {
  test("requires a marked throwaway QA bundle and disabled lifecycle", () => {
    const root = mkdtempSync(join(bundleFixtureRoot(), "vl-ui-"));
    writeFileSync(join(root, ".uie2e-sandbox"), "voicebar-ui-e2e-v1\n");
    try {
      for (const [app, qa, stop, relaunch, expected] of [
        [join(root, "VoiceBarQA.app"), "1", "0", "0", 0],
        ["/Applications/VoiceBar.app", "1", "0", "0", 1],
        [join(root, "VoiceBarQA.app"), "0", "0", "0", 1],
        [join(root, "VoiceBarQA.app"), "1", "1", "0", 1],
        [join(root, "VoiceBarQA.app"), "1", "0", "1", 1],
      ] as const) {
        const result = Bun.spawnSync(["bash", "-c", `
          source flow-bar/build-app.sh
          APP_DIR=$1; VOICEBAR_QA_BUILD=$2; STOP_RUNNING=$3; RELAUNCH_APP=$4
          allows_uie2e_adhoc_signing
        `, "test", app, qa, stop, relaunch], {
          env: { ...process.env, VOICEBAR_BUILD_APP_SOURCE_ONLY: "1", VOICEBAR_UIE2E_ADHOC: "1", VOICEBAR_CODESIGN_IDENTITY: "-" },
        });
        expect(result.exitCode).toBe(expected);
      }
    } finally { rmSync(root, { recursive: true }); }
  }, SUBPROCESS_TEST_TIMEOUT_MS);
});
