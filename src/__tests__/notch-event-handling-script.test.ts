import { describe, expect, test } from "bun:test";
import { readFileSync } from "fs";
import { join } from "path";

const repoRoot = new URL("../..", import.meta.url).pathname;
const scriptPath = join(
  repoRoot,
  "scripts",
  "verify-notch-event-handling.sh",
);

describe("verify-notch-event-handling.sh", () => {
  test("runs only an exact isolated app offscreen and cleans its PID", () => {
    const source = readFileSync(scriptPath, "utf8");

    expect(source).toContain("set -euo pipefail");
    expect(source).toContain("mktemp -d");
    expect(source).toContain("QA_VOICE_SOCKET_PATH");
    expect(source).toContain("QA_VOICE_MCP_SOCKET_PATH");
    expect(source).toContain("VOICEBAR_USER_DEFAULTS_SUITE");
    expect(source).toContain("QA_VOICEBAR_CAPTURE_OFFSCREEN=1");
    expect(source).toContain("VOICEBAR_QA_ALLOW_PARALLEL_INSTANCE=1");
    expect(source).toContain("VOICEBAR_QA_SKIP_LS_REGISTER=1");
    expect(source).toContain("offscreen_origin=-20000");
    expect(source).toContain("app_pid=$!");
    expect(source).toContain('kill "$app_pid"');
    expect(source).toContain('wait "$app_pid"');
    expect(source).toContain("isolated_marker_path");
    expect(source).not.toContain("pkill");
    expect(source).not.toContain("killall");
    expect(source).not.toContain("QA_VOICEBAR_CAPTURE_BOTTOM_LEFT");
    expect(source).not.toContain("QA_VOICEBAR_CAPTURE_TOP_RIGHT");
    expect(source).not.toContain("/Applications/VoiceBar.app");
  });

  test("drives every notch state and runs real AppKit event acceptance", () => {
    const source = readFileSync(scriptPath, "utf8");

    expect(source).toContain('for state_name in idle recording transcribing speaking');
    expect(source).toContain("testPanelAppKitMouseEventsHitOnlyMountedControls");
    expect(source).toContain("testTeleprompterAppKitMouseEventsPassThroughItsBody");
    expect(source).toContain("BarViewSnapshotArtifactTests");
    expect(source).toContain("VOICEBAR_VISUAL_ARTIFACT_OUTPUT");
    expect(source).toContain("trap cleanup EXIT INT TERM");
    expect(source).toContain("EVENT_HANDLING_OFFSCREEN_ACCEPTANCE");
  });
});
