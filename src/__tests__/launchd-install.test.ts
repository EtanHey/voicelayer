import { describe, expect, test } from "bun:test";
import {
  chmodSync,
  existsSync,
  mkdtempSync,
  mkdirSync,
  readFileSync,
  writeFileSync,
} from "fs";
import { tmpdir } from "os";
import { join } from "path";

const repoRoot = join(import.meta.dir, "..", "..");
const retiredDaemonPlist = join(
  repoRoot,
  "launchd",
  "com.voicelayer.mcp-daemon.plist",
);
const installScript = readFileSync(
  join(repoRoot, "launchd", "install.sh"),
  "utf-8",
);
const buildScript = readFileSync(
  join(repoRoot, "flow-bar", "build-app.sh"),
  "utf-8",
);
const voicebarAutostartScript = readFileSync(
  join(repoRoot, "scripts", "install-voicebar-autostart.sh"),
  "utf-8",
);
const voicebarAutostartScriptPath = join(
  repoRoot,
  "scripts",
  "install-voicebar-autostart.sh",
);

describe("MCP daemon LaunchAgent install contract", () => {
  test("retires the daemon LaunchAgent plist from the repo", () => {
    expect(existsSync(retiredDaemonPlist)).toBe(false);
  });

  test("installer removes the retired daemon LaunchAgent instead of installing it", () => {
    expect(installScript).toContain('LABEL="com.voicelayer.mcp-daemon"');
    expect(installScript).toContain("Retiring %s");
    expect(installScript).toContain('launchctl bootout "gui/$(id -u)/$LABEL"');
    expect(installScript).toContain('rm -f "$PLIST_DST"');
    expect(installScript).not.toContain("launchctl bootstrap");
    expect(installScript).not.toContain("plutil -lint");
  });

  test("installer leaves the disable flag under explicit caller control", () => {
    expect(installScript).toContain("/tmp/.voicelayer-daemon-disabled");
    expect(installScript).not.toContain('rm -f "$DAEMON_DISABLE_FLAG"');
    expect(installScript).not.toContain(
      'printf "disabled\\n" > "$DAEMON_DISABLE_FLAG"',
    );
  });

  test("VoiceBar rebuild does not install the retired daemon LaunchAgent", () => {
    expect(buildScript).toContain("launchd/install.sh");
    expect(buildScript).toContain("Retiring MCP daemon LaunchAgent");
    expect(buildScript).not.toContain("VOICEBAR_FORCE_LAUNCHD_INSTALL");
  });

  test("VoiceBar build script stores at most one app backup outside /Applications", () => {
    expect(buildScript).not.toContain("/Applications/VoiceBar.backup-");
    expect(buildScript).not.toMatch(
      /\/Applications\/[^"\n]*VoiceBar\.backup-.*\.app/,
    );
    expect(buildScript).toContain(
      'VOICEBAR_BACKUP_DIR="${VOICEBAR_BACKUP_DIR:-$HOME/Library/Application Support/VoiceBar/Backups}"',
    );
    expect(buildScript).toContain('mkdir -p "$VOICEBAR_BACKUP_DIR"');
    expect(buildScript).toContain('find "$VOICEBAR_BACKUP_DIR"');
  });

  test("VoiceBar autostart installer can reload a repaired loaded definition immediately", () => {
    expect(voicebarAutostartScript).toContain("--reload");
    expect(voicebarAutostartScript).toContain(
      'launchctl bootout "$DOMAIN/$LABEL"',
    );
    expect(voicebarAutostartScript).toContain(
      'launchctl bootstrap "$DOMAIN" "$PLIST_DST"',
    );
    expect(
      voicebarAutostartScript.indexOf('launchctl bootout "$DOMAIN/$LABEL"'),
    ).toBeLessThan(
      voicebarAutostartScript.lastIndexOf(
        'launchctl bootstrap "$DOMAIN" "$PLIST_DST"',
      ),
    );
  });

  test("VoiceBar autostart no-start unloads a loaded job and tolerates a concurrent unload", () => {
    const tempHome = mkdtempSync(join(tmpdir(), "voicebar-autostart-reload-"));
    const binDir = join(tempHome, "bin");
    const launchctlLog = join(tempHome, "launchctl.log");
    const launchctlState = join(tempHome, "launchctl.state");
    const launchctlStub = join(binDir, "launchctl");
    const plutilStub = join(binDir, "plutil");
    mkdirSync(binDir, { recursive: true });
    writeFileSync(
      launchctlStub,
      [
        "#!/usr/bin/env bash",
        'printf "%s\\n" "$*" >> "$VOICEBAR_TEST_LAUNCHCTL_LOG"',
        'state="$(cat "$VOICEBAR_TEST_LAUNCHCTL_STATE" 2>/dev/null || printf loaded)"',
        'if [[ "$1" == "print" ]]; then',
        '  [[ "$state" == "loaded" ]]',
        "  exit",
        "fi",
        'if [[ "$1" == "bootout" ]]; then',
        '  printf "unloaded\\n" > "$VOICEBAR_TEST_LAUNCHCTL_STATE"',
        "  exit 3",
        "fi",
        "exit 0",
        "",
      ].join("\n"),
    );
    chmodSync(launchctlStub, 0o755);
    writeFileSync(plutilStub, "#!/usr/bin/env bash\nexit 0\n");
    chmodSync(plutilStub, 0o755);
    writeFileSync(launchctlState, "loaded\n");

    const result = Bun.spawnSync(
      ["bash", voicebarAutostartScriptPath, "--no-start"],
      {
        cwd: repoRoot,
        stdout: "pipe",
        stderr: "pipe",
        env: {
          ...process.env,
          HOME: tempHome,
          PATH: `${binDir}:${process.env.PATH ?? ""}`,
          VOICEBAR_TEST_LAUNCHCTL_LOG: launchctlLog,
          VOICEBAR_TEST_LAUNCHCTL_STATE: launchctlState,
        },
      },
    );

    expect(result.exitCode).toBe(0);
    const launchctlCalls = readFileSync(launchctlLog, "utf-8");
    expect(launchctlCalls).toContain("bootout gui/");
    expect(launchctlCalls).not.toContain("bootstrap gui/");
    expect(launchctlCalls).not.toContain("kickstart gui/");
  });

  test("VoiceBar autostart reload waits for asynchronous bootout before bootstrap", () => {
    const tempHome = mkdtempSync(join(tmpdir(), "voicebar-autostart-wait-"));
    const binDir = join(tempHome, "bin");
    const launchctlLog = join(tempHome, "launchctl.log");
    const launchctlState = join(tempHome, "launchctl.state");
    const launchctlCount = join(tempHome, "launchctl.count");
    const launchctlStub = join(binDir, "launchctl");
    const plutilStub = join(binDir, "plutil");
    mkdirSync(binDir, { recursive: true });
    writeFileSync(
      launchctlStub,
      [
        "#!/usr/bin/env bash",
        'printf "%s\\n" "$*" >> "$VOICEBAR_TEST_LAUNCHCTL_LOG"',
        'state="$(cat "$VOICEBAR_TEST_LAUNCHCTL_STATE" 2>/dev/null || printf loaded)"',
        'if [[ "$1" == "print" ]]; then',
        '  [[ "$state" == "loaded" ]] && exit 0',
        '  if [[ "$state" == "draining" ]]; then',
        '    count="$(cat "$VOICEBAR_TEST_LAUNCHCTL_COUNT" 2>/dev/null || printf 0)"',
        '    count=$((count + 1))',
        '    printf "%s\\n" "$count" > "$VOICEBAR_TEST_LAUNCHCTL_COUNT"',
        '    if [[ "$count" -lt 3 ]]; then exit 0; fi',
        '    printf "unloaded\\n" > "$VOICEBAR_TEST_LAUNCHCTL_STATE"',
        "  fi",
        "  exit 1",
        "fi",
        'if [[ "$1" == "bootout" ]]; then',
        '  printf "draining\\n" > "$VOICEBAR_TEST_LAUNCHCTL_STATE"',
        "  exit 0",
        "fi",
        "exit 0",
        "",
      ].join("\n"),
    );
    chmodSync(launchctlStub, 0o755);
    writeFileSync(plutilStub, "#!/usr/bin/env bash\nexit 0\n");
    chmodSync(plutilStub, 0o755);
    writeFileSync(launchctlState, "loaded\n");

    const result = Bun.spawnSync(
      ["bash", voicebarAutostartScriptPath, "--reload"],
      {
        cwd: repoRoot,
        stdout: "pipe",
        stderr: "pipe",
        env: {
          ...process.env,
          HOME: tempHome,
          PATH: `${binDir}:${process.env.PATH ?? ""}`,
          VOICEBAR_TEST_LAUNCHCTL_LOG: launchctlLog,
          VOICEBAR_TEST_LAUNCHCTL_STATE: launchctlState,
          VOICEBAR_TEST_LAUNCHCTL_COUNT: launchctlCount,
        },
      },
    );

    expect(result.exitCode).toBe(0);
    expect(readFileSync(launchctlCount, "utf8").trim()).toBe("3");
    const launchctlCalls = readFileSync(launchctlLog, "utf8");
    expect(launchctlCalls.indexOf("bootout")).toBeLessThan(
      launchctlCalls.indexOf("bootstrap"),
    );
  });

  test("VoiceBar autostart installer can write an unloaded definition without starting it", () => {
    const tempHome = mkdtempSync(join(tmpdir(), "voicebar-autostart-no-start-"));
    const binDir = join(tempHome, "bin");
    const launchctlLog = join(tempHome, "launchctl.log");
    const launchctlStub = join(binDir, "launchctl");
    const plutilStub = join(binDir, "plutil");
    mkdirSync(binDir, { recursive: true });
    writeFileSync(
      launchctlStub,
      [
        "#!/usr/bin/env bash",
        'printf "%s\\n" "$*" >> "$VOICEBAR_TEST_LAUNCHCTL_LOG"',
        '[[ "$1" == "print" ]] && exit 1',
        "exit 0",
        "",
      ].join("\n"),
    );
    chmodSync(launchctlStub, 0o755);
    writeFileSync(plutilStub, "#!/usr/bin/env bash\nexit 0\n");
    chmodSync(plutilStub, 0o755);

    for (const mode of ["--no-start", "--preserve-load-state"]) {
      writeFileSync(launchctlLog, "");
      const result = Bun.spawnSync(
        ["bash", voicebarAutostartScriptPath, mode],
        {
          cwd: repoRoot,
          stdout: "pipe",
          stderr: "pipe",
          env: {
            ...process.env,
            HOME: tempHome,
            PATH: `${binDir}:${process.env.PATH ?? ""}`,
            VOICEBAR_TEST_LAUNCHCTL_LOG: launchctlLog,
          },
        },
      );

      expect(result.exitCode).toBe(0);
      expect(
        existsSync(
          join(
            tempHome,
            "Library",
            "LaunchAgents",
            "com.voicelayer.voicebar.plist",
          ),
        ),
      ).toBe(true);
      const launchctlCalls = readFileSync(launchctlLog, "utf-8");
      expect(launchctlCalls).toContain(
        "print gui/",
      );
      expect(launchctlCalls).not.toContain("bootstrap");
      expect(launchctlCalls).not.toContain("kickstart");
      expect(launchctlCalls).not.toMatch(/^(?:load|start|submit)\b/m);
    }
  });

  test("VoiceBar build script self-completes live app replacement with precise stop and relaunch", () => {
    const stopIndex = buildScript.indexOf("stop_voicebar_instances");
    const buildIndex = buildScript.indexOf("swift build -c release");
    const signIndex = buildScript.lastIndexOf("codesign --force --options runtime");
    const relaunchIndex = buildScript.lastIndexOf("relaunch_voicebar_app");

    expect(buildScript).toContain('VOICEBAR_BUNDLE_ID="com.voicelayer.voicebar"');
    expect(buildScript).toContain("CFBundleIdentifier");
    expect(buildScript).toContain("voicebar_target_pids");
    expect(buildScript).toContain("voicebar_descendant_pids");
    expect(buildScript).toContain("osascript -e");
    expect(buildScript).toContain("signal_pids TERM");
    expect(buildScript).toContain("signal_pids KILL");
    expect(buildScript).toContain('open "$APP_DIR"');
    expect(buildScript).toContain("wait_for_exactly_one_voicebar_instance");
    expect(stopIndex).toBeGreaterThan(-1);
    expect(buildIndex).toBeGreaterThan(stopIndex);
    expect(signIndex).toBeGreaterThan(buildIndex);
    expect(relaunchIndex).toBeGreaterThan(signIndex);
    expect(buildScript).toContain("--no-stop");
    expect(buildScript).toContain("--no-relaunch");
    expect(buildScript).not.toContain("VOICEBAR_FORCE_APP_REPLACE");
    expect(buildScript).not.toContain("Refusing to replace /Applications/VoiceBar.app");
    expect(buildScript).not.toMatch(/\b(pkill|killall)\b/);
  });
});
