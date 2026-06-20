import { describe, expect, test } from "bun:test";
import { existsSync, readFileSync } from "fs";
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

  test("VoiceBar build script self-completes live app replacement with precise stop and relaunch", () => {
    const stopIndex = buildScript.indexOf("stop_voicebar_instances");
    const buildIndex = buildScript.indexOf("swift build -c release");
    const signIndex = buildScript.indexOf("codesign --force --deep");
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
