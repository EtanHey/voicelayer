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
          '  | "IOConsoleUsers" = ({"kCGSSessionSecureInputPID"=59247})',
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
});
