import { describe, expect, test } from "bun:test";
import { spawnSync } from "child_process";
import { join } from "path";

const healthScript = join(
  import.meta.dir,
  "..",
  "..",
  "scripts",
  "verify-voicebar-hotkey-health.sh",
);
const healthScriptBody = Bun.file(healthScript).text();

function callFunction(command: string, env: Record<string, string> = {}) {
  return spawnSync(
    "bash",
    [
      "-c",
      'VOICEBAR_HOTKEY_HEALTH_SOURCE_ONLY=1 source "$1"; shift; ' + command,
      "_",
      healthScript,
    ],
    {
      encoding: "utf8",
      env: { ...process.env, ...env },
    },
  );
}

describe("verify-voicebar-hotkey-health.sh", () => {
  test("limits fallback bundle discovery to targeted and current-user temp roots", async () => {
    const body = await healthScriptBody;

    expect(body).toContain('bundle_search_roots+=("$TMPDIR")');
    expect(body).not.toContain('"$HOME/Downloads" /tmp /private/tmp /var/folders');
  });

  test("requires both VoiceBar source keys to map to F18", () => {
    const mapping = `(
      {
        HIDKeyboardModifierMappingDst = 30064771181;
        HIDKeyboardModifierMappingSrc = 30064771134;
      },
      {
        HIDKeyboardModifierMappingDst = 30064771181;
        HIDKeyboardModifierMappingSrc = 51539607759;
      }
    )`;

    const f5 = callFunction(
      'mapping_has_pair "$TEST_MAPPING" 30064771134 30064771181',
      { TEST_MAPPING: mapping },
    );
    const dictation = callFunction(
      'mapping_has_pair "$TEST_MAPPING" 51539607759 30064771181',
      { TEST_MAPPING: mapping },
    );
    const missing = callFunction(
      'mapping_has_pair "$TEST_MAPPING" 51539607759 999',
      { TEST_MAPPING: mapping },
    );

    expect(f5.status).toBe(0);
    expect(dictation.status).toBe(0);
    expect(missing.status).not.toBe(0);
  });

  test("extracts the app holding macOS Secure Input", () => {
    const enabled = callFunction(
      'secure_input_owner "$TEST_IOREG"',
      {
        TEST_IOREG:
          '  | "IOConsoleUsers" = ({"kCGSSessionSecureInputPID" = 59247})',
      },
    );
    const disabled = callFunction(
      'secure_input_owner "$TEST_IOREG"',
      { TEST_IOREG: '  | "IOConsoleUsers" = ({"kCGSSessionUserIDKey"=501})' },
    );

    expect(enabled.status).toBe(0);
    expect(enabled.stdout.trim()).toBe("59247");
    expect(disabled.status).not.toBe(0);
  });

  test("extracts the program from the loaded LaunchAgent definition", () => {
    const result = callFunction(
      'launchd_loaded_program "$TEST_LAUNCHD"',
      {
        TEST_LAUNCHD: [
          "gui/501/com.voicelayer.voicebar = {",
          "\tpath = /Users/test/Library/LaunchAgents/com.voicelayer.voicebar.plist",
          "\tprogram = /Applications/VoiceBar.app/Contents/MacOS/VoiceBar",
          "}",
        ].join("\n"),
      },
    );

    expect(result.status).toBe(0);
    expect(result.stdout.trim()).toBe(
      "/Applications/VoiceBar.app/Contents/MacOS/VoiceBar",
    );
  });

  test("matches a canonical running process when its app path contains spaces", () => {
    const result = callFunction(
      'canonical_process_rows "$TEST_PS" "$TEST_EXPECTED"',
      {
        TEST_EXPECTED:
          "/Users/test/Test Builds/VoiceBar.app/Contents/MacOS/VoiceBar",
        TEST_PS: [
          "  123 /Applications/Other.app/Contents/MacOS/Other",
          "  456 /Users/test/Test Builds/VoiceBar.app/Contents/MacOS/VoiceBar",
        ].join("\n"),
      },
    );

    expect(result.status).toBe(0);
    expect(result.stdout.trim()).toBe(
      "456 /Users/test/Test Builds/VoiceBar.app/Contents/MacOS/VoiceBar",
    );
  });

  test("classifies event-tap startup and permission failures", () => {
    const ready = callFunction(
      'event_tap_log_verdict "$TEST_LOG"',
      { TEST_LOG: "[HotkeyManager] Event tap started — keycodes: [79, 96]" },
    );
    const listenEventMissing = callFunction(
      'event_tap_log_verdict "$TEST_LOG"',
      { TEST_LOG: "[HotkeyManager] Input Monitoring permission not granted" },
    );
    const accessibilityMissing = callFunction(
      'event_tap_log_verdict "$TEST_LOG"',
      { TEST_LOG: "[HotkeyManager] Accessibility permission not granted" },
    );
    const unknown = callFunction(
      'event_tap_log_verdict "$TEST_LOG"',
      { TEST_LOG: "VoiceBar launched" },
    );

    expect(ready.stdout.trim()).toBe("ready");
    expect(listenEventMissing.stdout.trim()).toBe("input-monitoring-missing");
    expect(accessibilityMissing.stdout.trim()).toBe("accessibility-missing");
    expect(unknown.stdout.trim()).toBe("unknown");
  });

  test("uses the most recent event-tap status instead of a stale startup failure", () => {
    const recovered = callFunction(
      'event_tap_log_verdict "$TEST_LOG"',
      {
        TEST_LOG: [
          "[HotkeyManager] Input Monitoring permission not granted",
          "[HotkeyManager] Event tap started — keycodes: [79, 96]",
        ].join("\n"),
      },
    );
    const regressed = callFunction(
      'event_tap_log_verdict "$TEST_LOG"',
      {
        TEST_LOG: [
          "[HotkeyManager] Event tap started — keycodes: [79, 96]",
          "[HotkeyManager] Failed to create CGEventTap",
        ].join("\n"),
      },
    );

    expect(recovered.stdout.trim()).toBe("ready");
    expect(regressed.stdout.trim()).toBe("event-tap-failed");
  });
});
