import { describe, expect, test } from "bun:test";
import { readFileSync } from "fs";
import { join } from "path";

const repoRoot = new URL("../..", import.meta.url).pathname;
const scriptPath = join(repoRoot, "scripts", "verify-notch-glass-readability.sh");
const dismissalScriptPath = join(
  repoRoot,
  "scripts",
  "verify-notch-teleprompter-dismissal.sh",
);
const fixturePath = join(
  repoRoot,
  "flow-bar",
  "Sources",
  "NotchGlassBackdropFixture",
  "main.swift",
);

describe("verify-notch-glass-readability.sh", () => {
  test("isolates VoiceBar and grades three real frames for every backdrop", () => {
    const source = readFileSync(scriptPath, "utf8");

    expect(source).toContain("set -euo pipefail");
    expect(source).toContain("mktemp -d");
    expect(source).toContain("QA_VOICE_SOCKET_PATH");
    expect(source).toContain("QA_VOICE_MCP_SOCKET_PATH");
    expect(source).toContain("VOICEBAR_USER_DEFAULTS_SUITE");
    expect(source).toContain("QA_VOICEBAR_RENDER_SCALE_RECEIPT_PATH");
    expect(source).toContain("VOICEBAR_QA_ALLOW_PARALLEL_INSTANCE=1");
    expect(source).toContain("VOICEBAR_QA_SKIP_LS_REGISTER=1");
    expect(source).toContain("fixture_pid");
    expect(source).toContain("app_pid");
    expect(source).toContain('kill "$fixture_pid"');
    expect(source).toContain('kill "$app_pid"');
    expect(source).not.toContain("pkill");
    expect(source).not.toContain("killall");
    expect(source).not.toContain("/Applications/VoiceBar.app");
    expect(source).toContain("NotchGlassBackdropFixture");
    expect(source).toContain('for fixture_mode in busy black bright');
    expect(source).toContain('for frame_index in 1 2 3');
    expect(source).toContain("--glass-readability-only");
    expect(source).toContain("--glass-teleprompter-frames");
    expect(source).toContain("--glass-black-frames");
    expect(source).toContain("--glass-bright-frames");
    expect(source).toContain("trap cleanup EXIT INT TERM");
  });

  test("keeps VoiceBar unfocused behind an active controlled backdrop", () => {
    const fixture = readFileSync(fixturePath, "utf8");

    expect(fixture).toContain("NSApp.activate(ignoringOtherApps: true)");
  });

  test("captures the exact fixture window bounds across Docks and displays", () => {
    const source = readFileSync(scriptPath, "utf8");
    const dismissalSource = readFileSync(dismissalScriptPath, "utf8");
    const fixture = readFileSync(fixturePath, "utf8");

    expect(fixture).toContain("CGWindowListCopyWindowInfo");
    expect(fixture).toContain('"capture_rect"');
    expect(source).toContain("capture_rect");
    expect(source).not.toContain("bounds of window of desktop");
    expect(dismissalSource).toContain("capture_rect");
    expect(dismissalSource).not.toContain("bounds of window of desktop");
  });

  test("audits only the exact frame names produced by the current run", () => {
    const verifier = readFileSync(
      join(
        repoRoot,
        "flow-bar",
        "Sources",
        "NotchCaptureContrastVerifier",
        "main.swift",
      ),
      "utf8",
    );

    expect(verifier).toContain("VoiceBarNotchCaptureAudit.captureFrameNames");
  });

  test("persists the dismissal verifier output with the captured frames", () => {
    const source = readFileSync(dismissalScriptPath, "utf8");

    expect(source).toContain('tee "$receipt_dir/metrics.txt"');
    expect(source).toContain(
      "--teleprompter-dismissal-interior-region 0.12,0.62,0.74,0.13",
    );
  });
});
