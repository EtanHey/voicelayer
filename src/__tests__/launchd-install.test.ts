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
    expect(installScript).not.toContain('printf "disabled\\n" > "$DAEMON_DISABLE_FLAG"');
  });

  test("VoiceBar rebuild does not install the retired daemon LaunchAgent", () => {
    expect(buildScript).toContain("launchd/install.sh");
    expect(buildScript).toContain(
      "Retiring MCP daemon LaunchAgent",
    );
    expect(buildScript).not.toContain("VOICEBAR_FORCE_LAUNCHD_INSTALL");
    expect(buildScript).not.toContain("pgrep -x VoiceBar");
  });
});
