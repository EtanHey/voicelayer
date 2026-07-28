import { describe, expect, test } from "bun:test";
import { spawnSync } from "child_process";
import {
  chmodSync,
  mkdtempSync,
  mkdirSync,
  rmSync,
  writeFileSync,
} from "fs";
import { tmpdir } from "os";
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
    expect(body).not.toContain("/var/folders");
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
    const zero = callFunction(
      'secure_input_owner "$TEST_IOREG"',
      {
        TEST_IOREG:
          '  | "IOConsoleUsers" = ({"kCGSSessionSecureInputPID" = 0})',
      },
    );

    expect(enabled.status).toBe(0);
    expect(enabled.stdout.trim()).toBe("59247");
    expect(disabled.status).not.toBe(0);
    expect(zero.status).not.toBe(0);
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

  test("rejects VoiceBar launchd definitions outside the canonical user plist", async () => {
    const canonical =
      "/Users/test/Library/LaunchAgents/com.voicelayer.voicebar.plist";
    const stray =
      "/Library/LaunchDaemons/com.example.stale-voicebar.plist";
    const result = callFunction(
      'noncanonical_launchd_definitions "$TEST_DEFINITIONS" "$TEST_CANONICAL"',
      {
        TEST_CANONICAL: canonical,
        TEST_DEFINITIONS: [canonical, stray].join("\n"),
      },
    );
    const body = await healthScriptBody;

    expect(result.status).toBe(0);
    expect(result.stdout.trim()).toBe(stray);
    expect(body).toContain(
      '"$HOME/Library/LaunchAgents" /Library/LaunchAgents /Library/LaunchDaemons',
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

  test("reads the full process command rather than the truncated comm column", async () => {
    const body = await healthScriptBody;

    expect(body).toContain("ps -axo pid=,command=");
    expect(body).not.toContain("ps -axo pid=,comm=");
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

  test("preserves source order when event-tap records share a timestamp", () => {
    const failed = "2026-07-28 19:49:53 [HotkeyManager] Failed to create CGEventTap";
    const ready = "2026-07-28 19:49:53 [HotkeyManager] Event tap started";
    const failureThenReady = [failed, ready].join("\n");
    const readyThenFailure = [ready, failed].join("\n");
    const forward = callFunction(
      'printf "%s\\n" "$TEST_LOG" | chronological_event_tap_logs',
      { TEST_LOG: failureThenReady },
    );
    const reverse = callFunction(
      'printf "%s\\n" "$TEST_LOG" | chronological_event_tap_logs',
      { TEST_LOG: readyThenFailure },
    );

    expect(forward.status).toBe(0);
    expect(forward.stdout.trim()).toBe(failureThenReady);
    expect(reverse.status).toBe(0);
    expect(reverse.stdout.trim()).toBe(readyThenFailure);
  });

  test("--allow-stopped skips loaded-agent, Secure Input, and process probes", () => {
    const tempRoot = mkdtempSync(join(tmpdir(), "voicebar-health-stopped-"));
    const tempHome = join(tempRoot, "home");
    const binDir = join(tempRoot, "bin");
    const appDir = join(tempRoot, "VoiceBar.app");
    const infoPlist = join(appDir, "Contents", "Info.plist");
    const agentDir = join(tempHome, "Library", "LaunchAgents");
    const agentPlist = join(
      agentDir,
      "com.voicelayer.voicebar.plist",
    );
    const probeLog = join(tempRoot, "live-probes.log");
    mkdirSync(join(appDir, "Contents", "MacOS"), { recursive: true });
    mkdirSync(agentDir, { recursive: true });
    mkdirSync(binDir, { recursive: true });
    writeFileSync(
      infoPlist,
      [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
        '<plist version="1.0"><dict>',
        "<key>CFBundleIdentifier</key><string>com.voicelayer.voicebar</string>",
        "</dict></plist>",
        "",
      ].join("\n"),
    );
    writeFileSync(
      agentPlist,
      [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
        '<plist version="1.0"><dict>',
        "<key>ProgramArguments</key><array>",
        `<string>${appDir}/Contents/MacOS/VoiceBar</string>`,
        "</array>",
        "</dict></plist>",
        "",
      ].join("\n"),
    );
    const stubs: Record<string, string> = {
      codesign: [
        "#!/usr/bin/env bash",
        'if [[ "$1" == "-dvvv" ]]; then',
        '  printf "Authority=Developer ID Application: Test\\nTeamIdentifier=PPN23G925Y\\n" >&2',
        "fi",
        "exit 0",
        "",
      ].join("\n"),
      mdfind: `#!/usr/bin/env bash\nprintf "%s\\n" "$VOICEBAR_CANONICAL_APP"\n`,
      find: `#!/usr/bin/env bash\nprintf "%s\\n" "$VOICEBAR_CANONICAL_APP"\n`,
      grep: `#!/usr/bin/env bash\nprintf "%s\\n" "$HOME/Library/LaunchAgents/com.voicelayer.voicebar.plist"\n`,
      hidutil: [
        "#!/usr/bin/env bash",
        "cat <<'EOF'",
        "({",
        "HIDKeyboardModifierMappingSrc = 30064771134;",
        "HIDKeyboardModifierMappingDst = 30064771181;",
        "},{",
        "HIDKeyboardModifierMappingSrc = 51539607759;",
        "HIDKeyboardModifierMappingDst = 30064771181;",
        "})",
        "EOF",
        "",
      ].join("\n"),
      PlistBuddy: [
        "#!/usr/bin/env bash",
        'case "$2" in',
        '  "Print :CFBundleIdentifier") printf "com.voicelayer.voicebar\\n" ;;',
        '  "Print :ProgramArguments:0") printf "%s/Contents/MacOS/VoiceBar\\n" "$VOICEBAR_TEST_CANONICAL_APP" ;;',
        "  *) exit 1 ;;",
        "esac",
        "",
      ].join("\n"),
    };
    for (const [name, body] of Object.entries(stubs)) {
      const path = join(binDir, name);
      writeFileSync(path, body);
      chmodSync(path, 0o755);
    }
    for (const name of ["launchctl", "ioreg", "ps"]) {
      const path = join(binDir, name);
      writeFileSync(
        path,
        [
          "#!/usr/bin/env bash",
          'printf "%s\\n" "$0 $*" >> "$VOICEBAR_TEST_LIVE_PROBE_LOG"',
          "exit 97",
          "",
        ].join("\n"),
      );
      chmodSync(path, 0o755);
    }

    try {
      const result = spawnSync(
        "bash",
        [healthScript, "--allow-stopped"],
        {
          encoding: "utf8",
          env: {
            ...process.env,
            HOME: tempHome,
            PATH: `${binDir}:${process.env.PATH ?? ""}`,
            VOICEBAR_CANONICAL_APP: appDir,
            VOICEBAR_PLIST_BUDDY: join(binDir, "PlistBuddy"),
            VOICEBAR_TEST_CANONICAL_APP: appDir,
            VOICEBAR_TEST_LIVE_PROBE_LOG: probeLog,
          },
        },
      );

      expect(result.status).toBe(0);
      expect(result.stdout).toContain("HOTKEY HEALTH OK");
      expect(Bun.file(probeLog).size).toBe(0);
    } finally {
      rmSync(tempRoot, { recursive: true, force: true });
    }
  });
});
