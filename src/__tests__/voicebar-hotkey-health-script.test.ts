import { bundleFixtureRoot } from "./setup/bundle-fixtures";
import { describe, expect, test } from "bun:test";
import { spawnSync } from "child_process";
import {
  chmodSync,
  mkdtempSync,
  mkdirSync,
  rmSync,
  writeFileSync,
} from "fs";
import { join } from "path";

// Real subprocesses: standalone p95 <= 26 ms; 4x rounded up, with a 5 s scheduling floor.
const SUBPROCESS_TEST_TIMEOUT_MS = 5_000;
// Real subprocesses: standalone p95 <= 3963 ms; 4x rounded up, with a 5 s scheduling floor.
const SLOW_SUBPROCESS_TEST_TIMEOUT_MS = 16_000;

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
    expect(body).toContain('"$HOME/Library/LaunchAgents" /Library/LaunchAgents /Library/LaunchDaemons');
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
  }, SUBPROCESS_TEST_TIMEOUT_MS);

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
  }, SUBPROCESS_TEST_TIMEOUT_MS);

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
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("enumerates canonical and stray VoiceBar bundle processes, including paths with spaces", () => {
    const result = callFunction(
      'voicebar_process_rows "$TEST_PS"',
      {
        TEST_PS: [
          "  123 /Applications/Other.app/Contents/MacOS/Other",
          "  456 /Users/test/Test Builds/VoiceBar.app/Contents/MacOS/VoiceBar",
          "  789 /tmp/Stale Build/VoiceBar.app/Contents/MacOS/VoiceBar --restored",
        ].join("\n"),
      },
    );

    expect(result.status).toBe(0);
    expect(result.stdout.trim().split("\n")).toEqual([
      "456 /Users/test/Test Builds/VoiceBar.app/Contents/MacOS/VoiceBar",
      "789 /tmp/Stale Build/VoiceBar.app/Contents/MacOS/VoiceBar --restored",
    ]);
  }, SUBPROCESS_TEST_TIMEOUT_MS);

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
  }, SUBPROCESS_TEST_TIMEOUT_MS);

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
  }, SUBPROCESS_TEST_TIMEOUT_MS);

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
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("health exempts TTS resources but rejects executable strays and stale loaded programs", async () => {
    const tempRoot = mkdtempSync(join(bundleFixtureRoot(), "voicebar-health-stopped-"));
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
    // The real daemon executes Python, with a resource argument inside VoiceBar.
    const writeAgent = (file: string, label: string, program: string, arg0: string) =>
      writeFileSync(join(agentDir, file), `<plist version="1.0"><dict>
        <key>Label</key><string>${label}</string>
        ${program ? `<key>Program</key><string>${program}</string>` : ""}
        <key>ProgramArguments</key><array><string>${arg0}</string>
        <string>${appDir}/Contents/Resources/src/tts-daemon.py</string></array>
      </dict></plist>`);
    writeAgent("com.golems.tts-daemon.plist", "com.golems.tts-daemon", "", "/usr/bin/python3");
    writeAgent("com.voicelayer.voicebar.plist", "com.voicelayer.voicebar", `${appDir}/Contents/MacOS/VoiceBar`, "/usr/bin/python3");
    // Exact label wins even with a renamed file and a VoiceBar executable.
    writeAgent("renamed-tts.plist", "com.golems.tts-daemon", "", `${appDir}/Contents/MacOS/VoiceBar`);
    // Program takes precedence over argv[0] in both directions.
    writeAgent("resource-helper.plist", "com.example.helper", "/usr/bin/python3", `${appDir}/Contents/MacOS/VoiceBar`);
    const stubs: Record<string, string> = {
      plutil: '#!/bin/bash\n/usr/bin/python3 -c \'import plistlib,sys; plistlib.load(open(sys.argv[-1], "rb"))\' "$@"\n',
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
      grep: `#!/usr/bin/env bash\n/usr/bin/grep -rlE 'VoiceBar|voicelayer\\.voicebar' "$HOME/Library/LaunchAgents"\n`,
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
      PlistBuddy: `#!/usr/bin/python3
import plistlib, sys
with open(sys.argv[-1], "rb") as file:
    value = plistlib.load(file)
for key in sys.argv[2].split()[1].split(":")[1:]:
    value = value[int(key)] if isinstance(value, list) else value[key]
print(value)
`,
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
    writeFileSync(probeLog, "");

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

      expect(result.stderr).toBe("");
      expect(result.status).toBe(0);
      expect(result.stdout).toContain("HOTKEY HEALTH OK");
      const unloadedProbes = await Bun.file(probeLog).text();
      expect(unloadedProbes).toContain(join(binDir, "launchctl"));
      expect(unloadedProbes).not.toContain(join(binDir, "ioreg"));
      expect(unloadedProbes).not.toContain(join(binDir, "ps"));

      for (const [file, program, arg0] of [
        ["stray-argv.plist", "", "/old/VoiceBar.app/Contents/MacOS/VoiceBar"],
        ["stray-program.plist", "/old/VoiceBar.app/Contents/MacOS/VoiceBar", "/usr/bin/python3"],
      ]) {
        writeAgent(file, "com.golems.tts-daemon-copy", program, arg0);
        const stray = spawnSync("bash", [healthScript, "--allow-stopped"], {
          encoding: "utf8", env: { ...process.env, HOME: tempHome,
            PATH: `${binDir}:${process.env.PATH ?? ""}`, VOICEBAR_CANONICAL_APP: appDir,
            VOICEBAR_PLIST_BUDDY: join(binDir, "PlistBuddy"), VOICEBAR_TEST_LIVE_PROBE_LOG: probeLog },
        });
        expect(stray.status).toBe(1);
        expect(stray.stderr).toContain("Stray VoiceBar launchd definitions found:");
        expect(stray.stderr).toContain(join(agentDir, file));
        rmSync(join(agentDir, file));
      }

      writeFileSync(
        join(binDir, "launchctl"),
        [
          "#!/usr/bin/env bash",
          'printf "%s\\n" "$0 $*" >> "$VOICEBAR_TEST_LIVE_PROBE_LOG"',
          "cat <<'EOF'",
          "gui/501/com.voicelayer.voicebar = {",
          "  program = /tmp/StaleVoiceBar.app/Contents/MacOS/VoiceBar",
          "}",
          "EOF",
          "",
        ].join("\n"),
      );
      const staleLoaded = spawnSync(
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

      expect(staleLoaded.status).not.toBe(0);
      expect(staleLoaded.stderr).toContain(
        "loaded LaunchAgent targets /tmp/StaleVoiceBar.app",
      );
    } finally {
      rmSync(tempRoot, { recursive: true, force: true });
    }
  }, SLOW_SUBPROCESS_TEST_TIMEOUT_MS);
});
