import { describe, expect, test } from "bun:test";
import { readFileSync } from "fs";
import { join } from "path";

const repoRoot = join(import.meta.dir, "..", "..");
const plistTemplate = readFileSync(
  join(repoRoot, "launchd", "com.voicelayer.mcp-daemon.plist"),
  "utf-8",
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
  test("runs the daemon from the installed VoiceBar bundle by default", () => {
    expect(installScript).toContain("/Applications/VoiceBar.app");
    expect(installScript).toContain('BUNDLE_RESOURCES_DIR="$APP_DIR/Contents/Resources"');
    expect(installScript).toContain(
      '$BUNDLE_RESOURCES_DIR/src/mcp-server-daemon.ts',
    );
  });

  test("plist bakes in daemon runtime PATH needed by launchd", () => {
    expect(plistTemplate).toContain("__HOME__/.bun/bin");
    expect(plistTemplate).toContain(
      "/Library/Frameworks/Python.framework/Versions/3.13/bin",
    );
    expect(plistTemplate).toContain("/opt/homebrew/bin");
  });

  test("daemon logs go to a stable user log directory", () => {
    expect(plistTemplate).toContain("__LOG_DIR__");
    expect(plistTemplate).not.toContain("/tmp/voicelayer-mcp-daemon.stderr.log");
    expect(plistTemplate).not.toContain("/tmp/voicelayer-mcp-daemon.stdout.log");
  });

  test("VoiceBar rebuild reinstalls the MCP daemon LaunchAgent", () => {
    expect(buildScript).toContain("launchd/install.sh");
    expect(buildScript).toContain("VOICEBAR_SKIP_LAUNCHD_INSTALL");
  });
});
